// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { StateView } from "@v4-periphery/lens/StateView.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";

contract DeployDopplerV3FactoryUnichainSepolia is Script, Deployers {
    Airlock airlock;
    TokenFactory tokenFactory;
    UniswapV4Initializer uniswapV4Initializer;
    UniswapV3Initializer uniswapV3Initializer;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator uniswapV2LiquidityMigrator;
    DopplerDeployer dopplerDeployer;
    UniversalRouter universalRouter;
    StateView stateView;

    address constant uniRouterV2 = 0x920b806E40A00E02E7D2b94fFc89860fDaEd3640;
    address constant uniFactoryV2 = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address v3CoreFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    string public constant ENV_PRIVATE_KEY = "PRIVATE_KEY";

    function run() public {
        uint256 pk = vm.envUint(ENV_PRIVATE_KEY);

        vm.startBroadcast(pk);

        address account = vm.addr(pk);

        manager = PoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
        console2.log("manager: ", address(manager), " as Address");

        airlock = new Airlock(address(account));
        console2.log("airlock: ", address(airlock), " as Address");
        tokenFactory = new TokenFactory(address(airlock));
        console2.log("tokenFactory: ", address(tokenFactory), " as Address");
        dopplerDeployer = new DopplerDeployer(IPoolManager(manager));
        console2.log("dopplerDeployer: ", address(dopplerDeployer), " as Address");
        uniswapV4Initializer = new UniswapV4Initializer(address(airlock), IPoolManager(manager), dopplerDeployer);
        console2.log("v4Initializer: ", address(uniswapV4Initializer), " as Address");
        uniswapV3Initializer = new UniswapV3Initializer(address(airlock), IUniswapV3Factory(v3CoreFactory));
        console2.log("v3Initializer: ", address(uniswapV3Initializer), " as Address");
        governanceFactory = new GovernanceFactory(address(airlock));
        console2.log("governanceFactory: ", address(governanceFactory), " as Address");
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock), IUniswapV2Factory(uniFactoryV2), IUniswapV2Router02(uniRouterV2), address(account)
        );
        console2.log("migrator: ", address(uniswapV2LiquidityMigrator), " as Address");
        universalRouter = UniversalRouter(0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D);
        console2.log("universalRouter: ", address(universalRouter), " as Address");
        stateView = StateView(0xc199F1072a74D4e905ABa1A84d9a45E2546B6222);
        console2.log("stateView: ", address(stateView), " as Address");

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
