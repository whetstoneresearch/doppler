// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { Bundler } from "src/Bundler.sol";
import { LockableUniswapV3Initializer } from "src/LockableUniswapV3Initializer.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { AirlockMultisig } from "test/shared/AirlockMultisig.sol";
import { LaunchpadGovernanceFactory } from "src/LaunchpadGovernanceFactory.sol";
import { DookMulticurveInitializer } from "src/DookMulticurveInitializer.sol";
import { mineDookMulticurveInitializer, MineDookMulticurveInitializerParams } from "test/shared/AirlockMiner.sol";

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
        AirlockMultisig airlockMultisig = new AirlockMultisig(Airlock(payable(airlock)), signers);

        UniswapV2Migrator uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            airlock,
            IUniswapV2Factory(0x182a927119D56008d921126764bF884221b10f59),
            IUniswapV2Router02(0x4B2ab38DBF28D31D467aA8993f6c2585981D6804),
            address(airlockMultisig)
        );

        LockableUniswapV3Initializer lockableUniswapV3Initializer =
            new LockableUniswapV3Initializer(airlock, IUniswapV3Factory(0x961235a9020B05C44DF1026D956D1F4D78014276));

        Bundler bundler = new Bundler(
            Airlock(payable(airlock)),
            UniversalRouter(payable(0x0D97Dc33264bfC1c226207428A79b26757fb9dc3)),
            IQuoterV2(0x661E93cca42AfacB172121EF892830cA3b70F08d)
        );

        (bytes32 salt, address minedDookMulticurveInitializer) = mineDookMulticurveInitializer(
            MineDookMulticurveInitializerParams({
                airlock: airlock, poolManager: 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e, deployer: msg.sender
            })
        );

        DookMulticurveInitializer dookMulticurveInitializer = new DookMulticurveInitializer{ salt: salt }(
            airlock, IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e)
        );

        require(
            minedDookMulticurveInitializer == address(dookMulticurveInitializer),
            "Deployed DookMulticurveInitializer address mismatch"
        );

        // Whitelisting the initial modules
        address[] memory modules = new address[](6);
        modules[0] = address(tokenFactory);
        modules[1] = address(launchpadGovernanceFactory);
        modules[2] = address(governanceFactory);
        modules[3] = address(uniswapV2LiquidityMigrator);
        modules[4] = address(lockableUniswapV3Initializer);
        modules[5] = address(noOpGovernanceFactory);
        modules[6] = address(noOpMigrator);

        ModuleState[] memory states = new ModuleState[](6);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.LiquidityMigrator;
        states[4] = ModuleState.PoolInitializer;
        states[5] = ModuleState.GovernanceFactory;
        states[6] = ModuleState.LiquidityMigrator;

        Airlock(payable(airlock)).setModuleState(modules, states);

        // Transfer ownership to the actual protocol owner
        Airlock(payable(airlock)).transferOwnership(address(airlockMultisig));

        vm.stopBroadcast();
    }
}
