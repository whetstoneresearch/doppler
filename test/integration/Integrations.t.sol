// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { ISwapRouter } from "@v3-periphery/interfaces/ISwapRouter.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { UniswapV3Initializer } from "src/initializers/UniswapV3Initializer.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { UniswapV4MulticurveInitializer } from "src/initializers/UniswapV4MulticurveInitializer.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";
import { UniswapV4MigratorSplit } from "src/migrators/UniswapV4MigratorSplit.sol";
import { CloneERC20Factory } from "src/tokens/CloneERC20Factory.sol";
import { CloneERC20VotesFactory } from "src/tokens/CloneERC20VotesFactory.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import {
    BaseIntegrationTest,
    deployGovernanceFactory,
    deployNoOpGovernanceFactory,
    deployNoOpMigrator,
    deployTokenFactory,
    prepareGovernanceFactoryData,
    prepareTokenFactoryData
} from "test/integration/BaseIntegrationTest.sol";
import { deployCloneERC20Factory, prepareCloneERC20FactoryData } from "test/integration/CloneERC20Factory.t.sol";
import {
    deployCloneERC20VotesFactory,
    prepareCloneERC20VotesFactoryData
} from "test/integration/CloneERC20VotesFactory.t.sol";
import {
    deployDopplerHookMulticurveInitializer,
    prepareDopplerHookMulticurveInitializerData
} from "test/integration/DopplerHookInitializer.t.sol";
import {
    deployUniswapV3Initializer,
    prepareUniswapV3InitializerData
} from "test/integration/UniswapV3Initializer.t.sol";
import { deployUniswapV4Initializer, preparePoolInitializerData } from "test/integration/UniswapV4Initializer.t.sol";
import {
    deployUniswapV4MigratorSplit,
    prepareUniswapV4MigratorSplitData
} from "test/integration/UniswapV4MigratorSplitIntegration.t.sol";
import {
    deployUniswapV4MulticurveInitializer,
    prepareUniswapV4MulticurveInitializerData
} from "test/integration/UniswapV4MulticurveInitializer.t.sol";
import {
    UNISWAP_V2_FACTORY_MAINNET,
    UNISWAP_V2_ROUTER_MAINNET,
    UNISWAP_V3_FACTORY_MAINNET,
    UNISWAP_V3_ROUTER_MAINNET,
    WETH_MAINNET
} from "test/shared/Addresses.sol";

contract TokenFactoryUniswapV4InitializerNoOpGovernanceFactoryNoOpMigratorIntegrationTest is BaseIntegrationTest {
    function setUp() public override {
        super.setUp();

        name = "TokenFactoryUniswapV4InitializerNoOpGovernanceFactoryNoOpMigrator";

        TokenFactory tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");

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

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }
}

contract CloneERC20FactoryUniswapV4InitializerNoOpGovernanceFactoryNoOpMigratorIntegrationTest is BaseIntegrationTest {
    function setUp() public override {
        super.setUp();

        name = "CloneERC20FactoryUniswapV4InitializerNoOpGovernanceFactoryNoOpMigrator";

        CloneERC20Factory tokenFactory = deployCloneERC20Factory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");

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

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }
}

contract CloneERC20FactoryUniswapV4MulticurveInitializerNoOpGovernanceFactoryNoOpMigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        super.setUp();

        name = "CloneERC20FactoryUniswapV4MulticurveInitializerNoOpGovernanceFactoryNoOpMigrator";

        CloneERC20Factory tokenFactory = deployCloneERC20Factory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData = prepareCloneERC20FactoryData();

        (, UniswapV4MulticurveInitializer initializer) =
            deployUniswapV4MulticurveInitializer(vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        (bytes memory poolInitializerData) = prepareUniswapV4MulticurveInitializerData(address(0), address(0));
        createParams.poolInitializerData = poolInitializerData;
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }
}

contract CloneERC20FactoryDopplerHookMulticurveInitializerNoOpGovernanceFactoryNoOpMigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        super.setUp();

        name = "CloneERC20FactoryDopplerHookMulticurveInitializerNoOpGovernanceFactoryNoOpMigrator";

        CloneERC20Factory tokenFactory = deployCloneERC20Factory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData = prepareCloneERC20FactoryData();

        DopplerHookInitializer initializer =
            deployDopplerHookMulticurveInitializer(vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        (bytes memory poolInitializerData) = prepareDopplerHookMulticurveInitializerData(address(0), address(0));
        createParams.poolInitializerData = poolInitializerData;
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }
}

contract CloneVotesERC20FactoryUniswapV4MulticurveInitializerGovernanceFactoryNoOpMigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        super.setUp();

        name = "CloneVotesERC20FactoryUniswapV4MulticurveInitializerGovernanceFactoryNoOpMigrator";

        CloneERC20VotesFactory tokenFactory = deployCloneERC20VotesFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData = prepareCloneERC20VotesFactoryData();

        (, UniswapV4MulticurveInitializer initializer) =
            deployUniswapV4MulticurveInitializer(vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        (bytes memory poolInitializerData) = prepareUniswapV4MulticurveInitializerData(address(0), address(0));
        createParams.poolInitializerData = poolInitializerData;
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        GovernanceFactory governanceFactory = deployGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
        createParams.governanceFactoryData = prepareGovernanceFactoryData();
    }
}

contract CloneVotesERC20FactoryUniswapV4InitializerGovernanceFactoryUniswapV4MigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        super.setUp();

        name = "CloneVotesERC20FactoryUniswapV4InitializerGovernanceFactoryUniswapV4Migrator";

        CloneERC20VotesFactory tokenFactory = deployCloneERC20VotesFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData = prepareCloneERC20VotesFactoryData();

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

        (,, UniswapV4MigratorSplit migrator) = deployUniswapV4MigratorSplit(
            vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager), address(positionManager)
        );
        createParams.liquidityMigrator = migrator;
        createParams.liquidityMigratorData = prepareUniswapV4MigratorSplitData(airlock);

        GovernanceFactory governanceFactory = deployGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
        createParams.governanceFactoryData = prepareGovernanceFactoryData();
    }

    function _beforeMigrate() internal override {
        bool canMigrated;

        uint256 i;

        do {
            i++;
            deal(address(this), 0.1 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(pool)).poolKey();

            swapRouter.swap{ value: 0.0001 ether }(
                PoolKey({
                    currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing
                }),
                IPoolManager.SwapParams(true, -int256(0.0001 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(pool)).state();
            canMigrated = totalProceeds > Doppler(payable(pool)).minimumProceeds();

            vm.warp(block.timestamp + 200);
        } while (!canMigrated);

        vm.warp(block.timestamp + 1 days);
    }
}

contract CloneVotesERC20FactoryUniswapV4MulticurveInitializerGovernanceFactoryUniswapV4MigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        super.setUp();

        name = "CloneVotesERC20FactoryUniswapV4MulticurveInitializerGovernanceFactoryUniswapV4Migrator";

        CloneERC20VotesFactory tokenFactory = deployCloneERC20VotesFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData = prepareCloneERC20VotesFactoryData();

        (, UniswapV4MulticurveInitializer initializer) =
            deployUniswapV4MulticurveInitializer(vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        (bytes memory poolInitializerData) = prepareUniswapV4MulticurveInitializerData(address(0), address(0));
        createParams.poolInitializerData = poolInitializerData;
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        (,, UniswapV4MigratorSplit migrator) = deployUniswapV4MigratorSplit(
            vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager), address(positionManager)
        );
        createParams.liquidityMigrator = migrator;
        createParams.liquidityMigratorData = prepareUniswapV4MigratorSplitData(airlock);

        GovernanceFactory governanceFactory = deployGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
        createParams.governanceFactoryData = prepareGovernanceFactoryData();
    }

    function _beforeMigrate() internal override {
        bool isToken0 = false;
        bool isUsingEth = true;
        // bool isToken0 = asset < address(numeraire);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: int256(1e23),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        if (isUsingEth) {
            vm.deal(address(swapRouter), type(uint128).max);
        } else {
            // TestERC20(numeraire).approve(address(swapRouter), type(uint128).max);
        }
        (,, PoolKey memory poolKey,) =
            UniswapV4MulticurveInitializer(payable(address(createParams.poolInitializer))).getState(asset);
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }
}

contract TokenFactoryUniswapV3InitializerNoOpGovernanceFactoryUniswapV4MigratorIntegrationTest is BaseIntegrationTest {
    TestERC20 internal numeraire;
    bool internal isToken0;

    function setUp() public override {
        vm.createSelectFork(vm.envString("ETH_MAINNET_RPC_URL"), 21_093_509);
        super.setUp();

        name = "TokenFactoryUniswapV3InitializerNoOpGovernanceFactoryUniswapV4Migrator";

        numeraire = new TestERC20(0);

        TokenFactory tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        bytes32 salt = bytes32(uint256(123));
        address asset;
        (asset, createParams.tokenFactoryData) =
            prepareTokenFactoryData(vm, address(airlock), address(tokenFactory), salt);
        isToken0 = asset < address(numeraire);

        UniswapV3Initializer initializer = deployUniswapV3Initializer(vm, airlock, UNISWAP_V3_FACTORY_MAINNET);
        createParams.poolInitializer = initializer;
        createParams.poolInitializerData =
            prepareUniswapV3InitializerData(IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET), isToken0);
        createParams.salt = bytes32(uint256(123));
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;
        createParams.numeraire = address(numeraire);

        (,, UniswapV4MigratorSplit migrator) = deployUniswapV4MigratorSplit(
            vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager), address(positionManager)
        );
        createParams.liquidityMigrator = migrator;
        createParams.liquidityMigratorData = prepareUniswapV4MigratorSplitData(airlock);

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }

    function _beforeMigrate() internal override {
        numeraire.mint(address(this), 1e48);
        numeraire.approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                tokenIn: address(numeraire),
                tokenOut: asset,
                fee: uint24(3000),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: 1e48,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(isToken0 ? int24(-167_520) : int24(167_520))
            })
            );
    }
}
