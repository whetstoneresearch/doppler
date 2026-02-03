// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Script, console } from "forge-std/Script.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { LaunchpadGovernanceFactory } from "src/governance/LaunchpadGovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { LockableUniswapV3Initializer } from "src/initializers/LockableUniswapV3Initializer.sol";
import { IUniswapV3Factory, UniswapV3Initializer } from "src/initializers/UniswapV3Initializer.sol";
import { UniswapV4ScheduledMulticurveInitializer } from "src/initializers/UniswapV4ScheduledMulticurveInitializer.sol";
import {
    UniswapV4ScheduledMulticurveInitializerHook
} from "src/initializers/UniswapV4ScheduledMulticurveInitializerHook.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";
import {
    IUniswapV2Factory,
    IUniswapV2Router02,
    UniswapV2MigratorSplit
} from "src/migrators/UniswapV2MigratorSplit.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import { MineV4MigratorHookParams, mineV4ScheduledMulticurveHook } from "test/shared/AirlockMiner.sol";

contract DeployMonadMainnetScript is Script {
    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        address airlock = address(new Airlock(msg.sender));

        GovernanceFactory governanceFactory = new GovernanceFactory(airlock);
        TokenFactory tokenFactory = new TokenFactory(airlock);
        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();
        NoOpMigrator noOpMigrator = new NoOpMigrator(airlock);
        LaunchpadGovernanceFactory launchpadGovernanceFactory = new LaunchpadGovernanceFactory();

        address[] memory signers = new address[](1);
        signers[0] = msg.sender;
        AirlockMultisigTestnet airlockMultisig = new AirlockMultisigTestnet(signers);

        UniswapV2MigratorSplit uniswapV2LiquidityMigrator = new UniswapV2MigratorSplit(
            airlock,
            IUniswapV2Factory(0x182a927119D56008d921126764bF884221b10f59),
            IUniswapV2Router02(0x4B2ab38DBF28D31D467aA8993f6c2585981D6804),
            address(airlockMultisig)
        );

        LockableUniswapV3Initializer lockableUniswapV3Initializer =
            new LockableUniswapV3Initializer(airlock, IUniswapV3Factory(0x204FAca1764B154221e35c0d20aBb3c525710498));

        Bundler bundler = new Bundler(
            Airlock(payable(airlock)),
            UniversalRouter(payable(0x0D97Dc33264bfC1c226207428A79b26757fb9dc3)),
            IQuoterV2(0x661E93cca42AfacB172121EF892830cA3b70F08d)
        );

        // Using `CREATE` we can pre-compute the UniswapV4ScheduledMulticurveInitializer address for mining the hook address
        address precomputedV4Initializer = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        /// Mine salt for Multicurve hook address
        (bytes32 salt, address minedHook) = mineV4ScheduledMulticurveHook(
            MineV4MigratorHookParams({
                poolManager: 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e,
                migrator: precomputedV4Initializer,
                hookDeployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C
            })
        );

        // Deploy migrator with pre-mined hook address
        UniswapV4ScheduledMulticurveInitializer v4Initializer = new UniswapV4ScheduledMulticurveInitializer(
            airlock, IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e), IHooks(minedHook)
        );

        // Deploy hook with deployed migrator address
        UniswapV4ScheduledMulticurveInitializerHook hook = new UniswapV4ScheduledMulticurveInitializerHook{
            salt: salt
        }(
            IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e), address(v4Initializer)
        );

        /// Verify that the hook was set correctly in the UniswapV4MigratorSplit constructor
        require(address(v4Initializer.HOOK()) == address(hook), "Multicurve hook is not the expected address");

        // Whitelisting the initial modules
        address[] memory modules = new address[](8);
        ModuleState[] memory states = new ModuleState[](8);
        modules[0] = address(governanceFactory);
        states[0] = ModuleState.GovernanceFactory;
        modules[1] = address(noOpGovernanceFactory);
        states[1] = ModuleState.GovernanceFactory;
        modules[2] = address(launchpadGovernanceFactory);
        states[2] = ModuleState.GovernanceFactory;
        modules[3] = address(tokenFactory);
        states[3] = ModuleState.TokenFactory;
        modules[4] = address(noOpMigrator);
        states[4] = ModuleState.LiquidityMigrator;
        modules[5] = address(lockableUniswapV3Initializer);
        states[5] = ModuleState.PoolInitializer;
        modules[6] = address(uniswapV2LiquidityMigrator);
        states[6] = ModuleState.LiquidityMigrator;
        modules[7] = address(v4Initializer);
        states[7] = ModuleState.PoolInitializer;

        Airlock(payable(airlock)).setModuleState(modules, states);

        // Transfer ownership to the actual protocol owner
        Airlock(payable(airlock)).transferOwnership(address(airlockMultisig));

        vm.stopBroadcast();
    }
}
