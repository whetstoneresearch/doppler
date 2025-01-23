// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { StateView } from "@v4-periphery/lens/StateView.sol";
import { V4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { CustomRouter2 } from "test/shared/CustomRouter2.sol";
import { BasicRouter } from "test/shared/BasicRouter.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { RouterParameters } from "@universal-router/types/RouterParameters.sol";

bytes32 constant PAIR_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
bytes32 constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

contract DeployDopplerV3FactoryUnichainSepolia is Script, Deployers {
    Airlock airlock;
    TokenFactory tokenFactory;
    UniswapV4Initializer uniswapV4Initializer;
    UniswapV3Initializer uniswapV3Initializer;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator uniswapV2LiquidityMigrator;
    DopplerDeployer dopplerDeployer;
    UniversalRouter universalRouter;
    BasicRouter router;

    function setUp() public { }

    address constant uniRouterV2 = 0x920b806E40A00E02E7D2b94fFc89860fDaEd3640;
    address constant uniFactoryV2 = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    address constant stateView = 0xdE04C804dc75E90D8a64e5589092a1D6692EFA45;
    address constant uniRouter = 0x9e5A52f57b3038F1B8EeE45F28b3C1967e22799C;
    address constant weth = 0x4200000000000000000000000000000000000006;
    address constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address v3CoreFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    string public constant ENV_PRIVATE_KEY = "PRIVATE_KEY";

    function run() public {
        uint256 pk = vm.envUint(ENV_PRIVATE_KEY);

        vm.startBroadcast(pk);

        RouterParameters memory params = RouterParameters({
            permit2: permit2,
            weth9: weth,
            v2Factory: address(uniFactoryV2),
            v3Factory: address(v3CoreFactory),
            pairInitCodeHash: PAIR_INIT_CODE_HASH,
            poolInitCodeHash: POOL_INIT_CODE_HASH,
            v4PoolManager: address(manager),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(0)
        });

        address account = vm.addr(pk);

        manager = new PoolManager(address(this));
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
        uniswapV2LiquidityMigrator =
            new UniswapV2Migrator(address(airlock), IUniswapV2Factory(uniFactoryV2), IUniswapV2Router02(uniRouterV2));
        console2.log("migrator: ", address(uniswapV2LiquidityMigrator), " as Address");
        console2.log("stateView: ", address(stateView), " as Address");
        universalRouter = new UniversalRouter(params);
        router = new BasicRouter(address(universalRouter));
        console2.log("universalRouter: ", address(universalRouter), " as Address");
        console2.log("basicRouter: ", address(router), " as Address");

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
