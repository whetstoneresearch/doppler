// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
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

contract DeployMonadTestnetScript is Script {
    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        address airlock = address(new Airlock(msg.sender));

        GovernanceFactory governanceFactory = new GovernanceFactory(airlock);
        TokenFactory tokenFactory = new TokenFactory(airlock);
        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();
        NoOpMigrator noOpMigrator = new NoOpMigrator(airlock);

        address[] memory signers = new address[](1);
        signers[0] = msg.sender;
        AirlockMultisig airlockMultisig = new AirlockMultisig(Airlock(payable(airlock)), signers);

        UniswapV2Migrator uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            airlock,
            IUniswapV2Factory(0x733E88f248b742db6C14C0b1713Af5AD7fDd59D0),
            IUniswapV2Router02(0xfB8e1C3b833f9E67a71C859a132cf783b645e436),
            address(airlockMultisig)
        );

        UniswapV3Initializer uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(0x961235a9020B05C44DF1026D956D1F4D78014276));
        LockableUniswapV3Initializer lockableUniswapV3Initializer =
            new LockableUniswapV3Initializer(airlock, IUniswapV3Factory(0x961235a9020B05C44DF1026D956D1F4D78014276));

        Bundler bundler = new Bundler(
            Airlock(payable(airlock)),
            UniversalRouter(payable(0x3aE6D8A282D67893e17AA70ebFFb33EE5aa65893)),
            IQuoterV2(0x1b4E313fEF15630AF3e6F2dE550Dbf4cC9D3081d)
        );

        // Whitelisting the initial modules
        address[] memory modules = new address[](7);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV3Initializer);
        modules[2] = address(governanceFactory);
        modules[3] = address(uniswapV2LiquidityMigrator);
        modules[4] = address(lockableUniswapV3Initializer);
        modules[5] = address(noOpGovernanceFactory);
        modules[6] = address(noOpMigrator);

        ModuleState[] memory states = new ModuleState[](7);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
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
