// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/test/utils/Deployers.sol";
import { Airlock, ModuleState, WrongModuleState, SetModuleState } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { StateView } from "v4-periphery/src/lens/StateView.sol";
import { V4Quoter, IV4Quoter } from "v4-periphery/src/lens/V4Quoter.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";
import { CustomRouter2 } from "test/shared/CustomRouter2.sol";

contract DeployDopplerV3FactoryUnichainSepolia is Script {
    Airlock airlock;
    TokenFactory tokenFactory;
    UniswapV4Initializer uniswapV4Initializer;
    UniswapV3Initializer uniswapV3Initializer;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator uniswapV2LiquidityMigrator;
    DopplerDeployer dopplerDeployer;
    CustomRouter2 router;

    function setUp() public { }

    address constant uniRouterV2 = 0x920b806E40A00E02E7D2b94fFc89860fDaEd3640;
    address constant uniFactoryV2 = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    address constant manager = 0xC81462Fec8B23319F288047f8A03A57682a35C1A;
    address constant quoter = 0xfe6Cf50c4cfe801dd2AEf9c1B3ce24f551944df8;
    address constant stateView = 0xdE04C804dc75E90D8a64e5589092a1D6692EFA45;
    address constant uniRouter = 0x9e5A52f57b3038F1B8EeE45F28b3C1967e22799C;

    address v3CoreFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    string public constant ENV_PRIVATE_KEY = "PRIVATE_KEY";

    function run() public {
        uint256 pk = vm.envUint(ENV_PRIVATE_KEY);
        vm.startBroadcast(pk);

        address account = vm.addr(pk);
        airlock = new Airlock(address(account));
        console2.log("Airlock: ", address(airlock));
        tokenFactory = new TokenFactory(address(airlock));
        console2.log("TokenFactory: ", address(tokenFactory));
        dopplerDeployer = new DopplerDeployer(address(airlock), IPoolManager(manager));
        uniswapV4Initializer = new UniswapV4Initializer(address(airlock), IPoolManager(manager), dopplerDeployer);
        console2.log("UniswapV4Initializer: ", address(uniswapV4Initializer));
        uniswapV3Initializer = new UniswapV3Initializer(address(airlock), IUniswapV3Factory(v3CoreFactory));
        console2.log("UniswapV3Initializer: ", address(uniswapV3Initializer));
        governanceFactory = new GovernanceFactory(address(airlock));
        console2.log("GovernanceFactory: ", address(governanceFactory));
        uniswapV2LiquidityMigrator =
            new UniswapV2Migrator(address(airlock), IUniswapV2Factory(uniFactoryV2), IUniswapV2Router02(uniRouterV2));
        console2.log("Migrator: ", address(uniswapV2LiquidityMigrator));
        console2.log("StateView: ", address(stateView));
        console2.log("Quoter: ", address(quoter));
        router = new CustomRouter2(PoolSwapTest(uniRouter), V4Quoter(quoter));
        console2.log("CustomRouter: ", address(router));
        console2.log(airlock.owner());

        address[] memory modules = new address[](5);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV3Initializer);
        modules[2] = address(uniswapV4Initializer);
        modules[3] = address(governanceFactory);
        modules[4] = address(uniswapV2LiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](5);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.GovernanceFactory;
        states[4] = ModuleState.LiquidityMigrator;

        airlock.setModuleState(modules, states);

        vm.stopBroadcast();
    }
}
