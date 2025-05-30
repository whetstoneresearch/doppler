// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Deploy } from "@v4-periphery-test/shared/Deploy.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { DopplerDeployer, UniswapV4Initializer, IPoolInitializer } from "src/UniswapV4Initializer.sol";
import { UniswapV4Migrator, ILiquidityMigrator } from "src/UniswapV4Migrator.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory, IGovernanceFactory } from "src/GovernanceFactory.sol";
import { Doppler } from "src/Doppler.sol";

contract V4MigratorTest is BaseTest, DeployPermit2 {
    IAllowanceTransfer public permit2;
    UniswapV4Migrator public migrator;
    IPositionManager public positionManager;
    Airlock public airlock;
    DopplerDeployer public deployer;
    UniswapV4Initializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;

    function test_migrate_v4() public {
        permit2 = IAllowanceTransfer(deployPermit2());

        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        positionManager = Deploy.positionManager(
            address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
        );

        migrator = new UniswapV4Migrator(address(airlock), address(manager), payable(address(positionManager)));
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        airlock.setModuleState(modules, states);

        uint256 initialSupply = 1e23;

        bytes memory tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");
        bytes memory poolInitializerData = abi.encode(
            0.01 ether,
            10 ether,
            block.timestamp,
            block.timestamp + 1 days,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            200,
            800,
            false,
            10,
            200,
            2
        );

        bytes memory migratorData = abi.encode(2000, 8);

        MineV4Params memory params = MineV4Params({
            airlock: address(airlock),
            poolManager: address(manager),
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(0),
            tokenFactory: ITokenFactory(address(tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: UniswapV4Initializer(address(initializer)),
            poolInitializerData: poolInitializerData
        });

        (bytes32 salt, address hook, address asset) = mineV4(params);

        CreateParams memory createParams = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(0),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(migrator),
            liquidityMigratorData: migratorData,
            integrator: address(0),
            salt: salt
        });

        airlock.create(createParams);

        bool canMigrated;

        do {
            deal(address(this), 0.1 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(hook)).poolKey();

            BalanceDelta delta = swapRouter.swap{ value: 0.1 ether }(
                PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing }),
                IPoolManager.SwapParams(true, -int256(0.1 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            canMigrated = totalProceeds > Doppler(payable(hook)).minimumProceeds();

            vm.warp(block.timestamp + 200);

            console.log("delta0", delta.amount0());
            console.log("delta1", delta.amount1());
        } while (!canMigrated);

        vm.warp(block.timestamp + 1 days + 1);
        airlock.migrate(asset);
    }
}
