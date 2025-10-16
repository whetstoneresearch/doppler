// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Deploy } from "@v4-periphery-test/shared/Deploy.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { DopplerDeployer, UniswapV4Initializer, IPoolInitializer } from "src/UniswapV4Initializer.sol";
import { UniswapV4Migrator, ILiquidityMigrator } from "src/UniswapV4Migrator.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory, IGovernanceFactory } from "src/GovernanceFactory.sol";
import { StreamableFeesLocker, BeneficiaryData } from "src/StreamableFeesLocker.sol";
import { Doppler } from "src/Doppler.sol";

import { BaseIntegrationTest } from "test/shared/BaseIntegrationTest.sol";

function deployUniswapV4Migrator(
    Vm vm,
    function(string memory, bytes memory, address) deployCodeTo,
    Airlock airlock,
    address airlockOwner,
    address poolManager,
    address positionManager
) returns (StreamableFeesLocker locker, UniswapV4MigratorHook migratorHook, UniswapV4Migrator migrator) {
    locker = new StreamableFeesLocker(IPositionManager(positionManager), airlockOwner);
    migratorHook = UniswapV4MigratorHook(
        address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
                ^ (0x4444 << 144)
        )
    );
    migrator = new UniswapV4Migrator(
        address(airlock),
        IPoolManager(poolManager),
        PositionManager(payable(positionManager)),
        locker,
        IHooks(migratorHook)
    );
    deployCodeTo("UniswapV4MigratorHook", abi.encode(address(poolManager), address(migrator)), address(migratorHook));

    address[] memory modules = new address[](1);
    modules[0] = address(migrator);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.LiquidityMigrator;
    vm.startPrank(airlockOwner);
    airlock.setModuleState(modules, states);
    locker.approveMigrator(address(migrator));
    vm.stopPrank();
}

contract V4MigratorTest is BaseTest, DeployPermit2 {
    IAllowanceTransfer public permit2;
    UniswapV4Migrator public migrator;
    UniswapV4MigratorHook public migratorHook;
    IPositionManager public positionManager;
    Airlock public airlock;
    DopplerDeployer public deployer;
    UniswapV4Initializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    StreamableFeesLocker public locker;

    // Solidity doesn't like it when you pass an overloaded function as an argument so we wrap it
    function _deployCodeTo(
        string memory what,
        bytes memory args,
        address where
    ) internal {
        deployCodeTo(what, args, where);
    }

    function setUp() public override {
        super.setUp();

        permit2 = IAllowanceTransfer(deployPermit2());
        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        positionManager = Deploy.positionManager(
            address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
        );
        (locker, migratorHook, migrator) = deployUniswapV4Migrator(
            vm, _deployCodeTo, airlock, address(this), address(manager), address(positionManager)
        );
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
    }

    function test_migrate_v4(
        int16 tickSpacing
    ) public {
        vm.assume(tickSpacing >= TickMath.MIN_TICK_SPACING && tickSpacing <= TickMath.MAX_TICK_SPACING);

        address integrator = makeAddr("integrator");

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

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: integrator, shares: 0.05e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: address(0xb0b), shares: 0.9e18 });
        beneficiaries = sortBeneficiaries(beneficiaries);

        bytes memory migratorData = abi.encode(2000, tickSpacing, 30 days, beneficiaries);

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
            integrator: integrator,
            salt: salt
        });

        airlock.create(createParams);

        bool canMigrated;

        uint256 i;

        do {
            i++;
            deal(address(this), 0.1 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(hook)).poolKey();

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

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            canMigrated = totalProceeds > Doppler(payable(hook)).minimumProceeds();

            vm.warp(block.timestamp + 200);
        } while (!canMigrated);

        goToEndingTime();
        airlock.migrate(asset);
    }

    function sortBeneficiaries(
        BeneficiaryData[] memory beneficiaries
    ) internal pure returns (BeneficiaryData[] memory) {
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
}
