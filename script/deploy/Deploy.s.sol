// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";
import { IPoolManager, IHooks } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager, PositionManager } from "@v4-periphery/PositionManager.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { MineV4MigratorHookParams, mineV4MigratorHook } from "test/shared/AirlockMiner.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { Bundler } from "src/Bundler.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";
import { LockableUniswapV3Initializer } from "src/LockableUniswapV3Initializer.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { AirlockMultisig } from "test/shared/AirlockMultisig.sol";

struct ScriptData {
    uint256 chainId;
    address poolManager;
    address protocolOwner;
    address quoterV2;
    address uniswapV2Factory;
    address uniswapV2Router02;
    address uniswapV3Factory;
    address universalRouter;
    address stateView;
    address positionManager;
}

/**
 * @notice Main script that will deploy the Airlock contract, the modules and the periphery contracts.
 * @dev This contract is meant to be inherited to target specific chains.
 */
abstract contract DeployScript is Script {
    ScriptData internal _scriptData;

    /// @dev This function is meant to be overridden in the child contract to set up the script data.
    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        (
            Airlock airlock,
            TokenFactory tokenFactory,
            UniswapV3Initializer uniswapV3Initializer,
            UniswapV4Initializer uniswapV4Initializer,
            GovernanceFactory governanceFactory,
            UniswapV2Migrator uniswapV2Migrator,
            DopplerDeployer dopplerDeployer,
            StreamableFeesLocker streamableFeesLocker,
            UniswapV4Migrator uniswapV4Migrator,
            UniswapV4MigratorHook migratorHook
        ) = _deployDoppler(_scriptData);

        Bundler bundler = _deployBundler(_scriptData, airlock);

        DopplerLensQuoter lens = _deployLens(_scriptData);

        vm.stopBroadcast();
    }

    function _deployDoppler(
        ScriptData memory scriptData
    )
        internal
        returns (
            Airlock airlock,
            TokenFactory tokenFactory,
            UniswapV3Initializer uniswapV3Initializer,
            UniswapV4Initializer uniswapV4Initializer,
            GovernanceFactory governanceFactory,
            UniswapV2Migrator uniswapV2LiquidityMigrator,
            DopplerDeployer dopplerDeployer,
            StreamableFeesLocker streamableFeesLocker,
            UniswapV4Migrator uniswapV4Migrator,
            UniswapV4MigratorHook migratorHook
        )
    {
        require(scriptData.uniswapV2Factory != address(0), "Cannot find UniswapV2Factory address!");
        require(scriptData.uniswapV2Router02 != address(0), "Cannot find UniswapV2Router02 address!");
        require(scriptData.uniswapV3Factory != address(0), "Cannot find UniswapV3Factory address!");

        // Airlock

        // Let's check that a valid protocol owner is set
        require(scriptData.protocolOwner != address(0), "Protocol owner not set!");
        console.log(unicode"👑 Protocol owner set as %s", scriptData.protocolOwner);

        // Owner of the protocol is first set as the deployer to allow the whitelisting of modules,
        // ownership is then transferred to the address defined as the "protocol_owner"
        airlock = new Airlock(msg.sender);

        streamableFeesLocker =
            new StreamableFeesLocker(IPositionManager(_scriptData.positionManager), _scriptData.protocolOwner);

        // Pool Initializer Modules
        uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(_scriptData.uniswapV3Factory));
        LockableUniswapV3Initializer lockableUniswapV3Initializer =
            new LockableUniswapV3Initializer(address(airlock), IUniswapV3Factory(_scriptData.uniswapV3Factory));

        // Using `CREATE` we can pre-compute the UniswapV4Migrator address for mining the hook address
        address precomputedUniswapV4Migrator = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        /// Mine salt for migrator hook address
        (bytes32 salt, address minedMigratorHook) = mineV4MigratorHook(
            MineV4MigratorHookParams({
                poolManager: _scriptData.poolManager,
                migrator: precomputedUniswapV4Migrator,
                hookDeployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C
            })
        );

        // Deploy migrator with pre-mined hook address
        uniswapV4Migrator = new UniswapV4Migrator(
            address(airlock),
            IPoolManager(_scriptData.poolManager),
            PositionManager(payable(_scriptData.positionManager)),
            streamableFeesLocker,
            IHooks(minedMigratorHook)
        );

        // Deploy hook with deployed migrator address
        migratorHook = new UniswapV4MigratorHook{ salt: salt }(IPoolManager(_scriptData.poolManager), uniswapV4Migrator);
        dopplerDeployer = new DopplerDeployer(IPoolManager(_scriptData.poolManager));
        uniswapV4Initializer =
            new UniswapV4Initializer(address(airlock), IPoolManager(_scriptData.poolManager), dopplerDeployer);

        // Liquidty Migrator Modules
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(_scriptData.uniswapV2Factory),
            IUniswapV2Router02(_scriptData.uniswapV2Router02),
            _scriptData.protocolOwner
        );

        NoOpMigrator noOpMigrator = new NoOpMigrator(address(airlock));

        // Token Factory modules
        tokenFactory = new TokenFactory(address(airlock));

        // Governance Factory modules
        governanceFactory = new GovernanceFactory(address(airlock));
        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();

        /// Verify that the hook was set correctly in the UniswapV4Migrator constructor
        require(
            address(uniswapV4Migrator.migratorHook()) == address(migratorHook),
            "Migrator hook is not the expected address"
        );

        // Whitelisting the initial modules
        address[] memory modules = new address[](7);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV3Initializer);
        modules[2] = address(governanceFactory);
        modules[3] = address(uniswapV2LiquidityMigrator);
        modules[4] = address(uniswapV4Initializer);
        modules[5] = address(uniswapV4Migrator);
        modules[6] = address(lockableUniswapV3Initializer);
        modules[7] = address(noOpGovernanceFactory);
        modules[8] = address(noOpMigrator);

        ModuleState[] memory states = new ModuleState[](7);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.LiquidityMigrator;
        states[4] = ModuleState.PoolInitializer;
        states[5] = ModuleState.LiquidityMigrator;
        states[6] = ModuleState.PoolInitializer;
        states[7] = ModuleState.GovernanceFactory;
        states[8] = ModuleState.LiquidityMigrator;

        airlock.setModuleState(modules, states);

        // Deploy the Airlock Multisig and transfer ownership to it
        address[] memory signers = new address[](1);
        signers[0] = msg.sender;

        AirlockMultisig airlockMultisig = new AirlockMultisig(airlock, signers);

        // Transfer ownership to the actual protocol owner
        airlock.transferOwnership(address(airlockMultisig));
    }

    function _deployBundler(ScriptData memory scriptData, Airlock airlock) internal returns (Bundler bundler) {
        require(scriptData.universalRouter != address(0), "Cannot find UniversalRouter address!");
        require(scriptData.quoterV2 != address(0), "Cannot find QuoterV2 address!");
        bundler =
            new Bundler(airlock, UniversalRouter(payable(scriptData.universalRouter)), IQuoterV2(scriptData.quoterV2));
    }

    function _deployLens(
        ScriptData memory scriptData
    ) internal returns (DopplerLensQuoter lens) {
        require(scriptData.poolManager != address(0), "Cannot find PoolManager address!");
        require(scriptData.stateView != address(0), "Cannot find StateView address!");
        lens = new DopplerLensQuoter(IPoolManager(scriptData.poolManager), IStateView(scriptData.stateView));
    }
}
