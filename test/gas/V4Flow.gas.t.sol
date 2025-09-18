// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
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
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { DopplerDeployer, UniswapV4Initializer, IPoolInitializer } from "src/UniswapV4Initializer.sol";
import { UniswapV4Migrator, ILiquidityMigrator } from "src/UniswapV4Migrator.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory, IGovernanceFactory } from "src/GovernanceFactory.sol";
import { StreamableFeesLocker, BeneficiaryData } from "src/StreamableFeesLocker.sol";
import { Doppler } from "src/Doppler.sol";

/**
 * @dev This is not a test but a gas benchmark for the V4 flow
 */
contract V4FlowGas is Deployers, DeployPermit2 {
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

    address integrator = makeAddr("integrator");

    function setUp() public {
        deployFreshManagerAndRouters();

        permit2 = IAllowanceTransfer(deployPermit2());
        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        positionManager = Deploy.positionManager(
            address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
        );
        locker = new StreamableFeesLocker(positionManager, address(this));
        migratorHook = UniswapV4MigratorHook(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG) ^ (0x4444 << 144)));
        migrator = new UniswapV4Migrator(
            address(airlock),
            IPoolManager(manager),
            PositionManager(payable(address(positionManager))),
            locker,
            IHooks(migratorHook)
        );
        deployCodeTo("UniswapV4MigratorHook", abi.encode(address(manager), address(migrator)), address(migratorHook));
        locker.approveMigrator(address(migrator));
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
    }

    function test_v4_flow_gas() public {
        uint256 startingTime = block.timestamp;
        uint256 endingTime = startingTime + 1 days;

        uint256 initialSupply = 1e23;

        bytes memory tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");
        bytes memory poolInitializerData =
            abi.encode(0.01 ether, 10 ether, startingTime, endingTime, 174_312, 186_840, 200, 800, false, 10, 200, 2);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(airlock), shares: 0.05e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: integrator, shares: 0.05e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: address(0xb0b), shares: 0.9e18 });
        beneficiaries = sortBeneficiaries(beneficiaries);

        bytes memory migratorData = abi.encode(2000, 8, 30 days, beneficiaries);

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

        vm.startSnapshotGas("V4 Flow", "AirlockCreateCall");
        (, address pool, address governance, address timelock, address migrationPool) = airlock.create(createParams);
        vm.stopSnapshotGas("V4 Flow", "AirlockCreateCall");

        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        vm.startSnapshotGas("V4 Flow", "First buy");
        swapRouter.swap{ value: 0.0001 ether }(
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing }),
            IPoolManager.SwapParams(true, -int256(0.0001 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopSnapshotGas("V4 Flow", "First buy");

        uint256 epochLength = Doppler(payable(hook)).epochLength();

        vm.warp(startingTime + epochLength);
        vm.startSnapshotGas("V4 Flow", "Second buy (new epoch)");
        swapRouter.swap{ value: 0.0001 ether }(
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing }),
            IPoolManager.SwapParams(true, -int256(0.0001 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopSnapshotGas("V4 Flow", "Second buy (new epoch)");

        vm.startSnapshotGas("V4 Flow", "Third buy (same epoch)");
        swapRouter.swap{ value: 0.0001 ether }(
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing }),
            IPoolManager.SwapParams(true, -int256(0.0001 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopSnapshotGas("V4 Flow", "Third buy (same epoch)");

        uint256 totalEpochs = (endingTime - startingTime) / epochLength;

        vm.warp(startingTime + epochLength * (totalEpochs / 2));
        vm.startSnapshotGas("V4 Flow", "Fourth buy (epoch #10)");
        swapRouter.swap{ value: 0.0001 ether }(
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing }),
            IPoolManager.SwapParams(true, -int256(0.0001 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopSnapshotGas("V4 Flow", "Fourth buy (epoch #10)");

        /*
        vm.warp(startingTime + epochLength * (totalEpochs - 1));
        vm.startSnapshotGas("V4 Flow", "Last buy (final epoch)");
        swapRouter.swap{ value: 0.0001 ether }(
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing }),
            IPoolManager.SwapParams(true, -int256(0.0001 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopSnapshotGas("V4 Flow", "Last buy (final epoch)");
        */

        bool canMigrated;

        do {
            deal(address(this), 0.1 ether);

            swapRouter.swap{ value: 0.0001 ether }(
                PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing }),
                IPoolManager.SwapParams(true, -int256(0.0001 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            canMigrated = totalProceeds > Doppler(payable(hook)).minimumProceeds();

            vm.warp(block.timestamp + 200);
        } while (!canMigrated);

        vm.warp(block.timestamp + 1 days + 1);
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
