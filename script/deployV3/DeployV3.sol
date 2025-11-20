// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { Airlock } from "src/Airlock.sol";
import { GovernanceFactory } from "src/modules/governance/GovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/modules/governance/NoOpGovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/modules/governance/NoOpGovernanceFactory.sol";
import { LockableUniswapV3Initializer } from "src/modules/initializers/LockableUniswapV3Initializer.sol";
import { IUniswapV3Factory, UniswapV3Initializer } from "src/modules/initializers/UniswapV3Initializer.sol";
import { NoOpMigrator } from "src/modules/migrators/NoOpMigrator.sol";
import { TokenFactory } from "src/modules/token/TokenFactory.sol";
import { AirlockMultisig } from "test/shared/AirlockMultisig.sol";

struct ScriptData {
    uint256 chainId;
    address uniswapV3Factory;
}

abstract contract DeployV3Script is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        require(_scriptData.chainId == block.chainid, "Invalid chainId");
        vm.startBroadcast();

        require(_scriptData.uniswapV3Factory != address(0), "Cannot find UniswapV3Factory address!");

        // Airlock
        Airlock airlock = new Airlock(msg.sender);

        // Pool Initializer modules
        UniswapV3Initializer uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(_scriptData.uniswapV3Factory));
        LockableUniswapV3Initializer lockableUniswapV3Initializer =
            new LockableUniswapV3Initializer(address(airlock), IUniswapV3Factory(_scriptData.uniswapV3Factory));

        // Token Factory modules
        TokenFactory tokenFactory = new TokenFactory(address(airlock));

        // Governance Factory modules
        GovernanceFactory governanceFactory = new GovernanceFactory(address(airlock));
        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();

        // Liquidity Migrator modules
        NoOpMigrator noOpMigrator = new NoOpMigrator(address(airlock));

        // Deploy the Airlock Multisig and transfer ownership to it
        address[] memory signers = new address[](1);
        signers[0] = msg.sender;

        AirlockMultisig airlockMultisig = new AirlockMultisig(airlock, signers);

        vm.stopBroadcast();
    }
}
