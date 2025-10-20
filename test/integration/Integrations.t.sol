// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import {
    BaseIntegrationTest,
    deployTokenFactory,
    deployNoOpMigrator,
    deployNoOpGovernanceFactory,
    prepareTokenFactoryData,
    deployGovernanceFactory,
    prepareGovernanceFactoryData
} from "test/integration/BaseIntegrationTest.sol";
import { Doppler } from "src/Doppler.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/UniswapV4Initializer.sol";
import { deployUniswapV4Initializer, preparePoolInitializerData } from "test/integration/UniswapV4Initializer.t.sol";
import {
    deployUniswapV4MulticurveInitializer,
    prepareUniswapV4MulticurveInitializerData
} from "test/integration/UniswapV4MulticurveInitializer.t.sol";
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";
import { deployCloneERC20Factory, prepareCloneERC20FactoryData } from "test/integration/CloneERC20Factory.t.sol";
import { CloneERC20Factory } from "src/CloneERC20Factory.sol";
import {
    deployCloneERC20VotesFactory,
    prepareCloneERC20VotesFactoryData
} from "test/integration/CloneERC20VotesFactory.t.sol";
import { CloneERC20VotesFactory } from "src/CloneERC20VotesFactory.sol";
import {
    deployUniswapV4Migrator,
    prepareUniswapV4MigratorData
} from "test/integration/UniswapV4MigratorIntegration.t.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";

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

        (,, UniswapV4Migrator migrator) = deployUniswapV4Migrator(
            vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager), address(positionManager)
        );
        createParams.liquidityMigrator = migrator;
        createParams.liquidityMigratorData = prepareUniswapV4MigratorData(airlock);

        GovernanceFactory governanceFactory = deployGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
        createParams.governanceFactoryData = prepareGovernanceFactoryData();
    }

    function _prepareMigrate() internal override {
        bool canMigrated;

        uint256 i;

        do {
            i++;
            deal(address(this), 0.1 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(pool)).poolKey();

            swapRouter.swap{
                value: 0.0001 ether
            }(
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
