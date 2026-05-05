/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { DecayMulticurveInitializer } from "src/initializers/DecayMulticurveInitializer.sol";
import { DecayMulticurveInitializerHook } from "src/initializers/DecayMulticurveInitializerHook.sol";
import { mineDecayMulticurveInitializer } from "test/shared/AirlockMiner.sol";

/**
 * @title Doppler Uniswap V4 Decay Multicurve Initializer Deployment Script
 */
contract DeployDecayMulticurveInitializerScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](1);
        // targets[0] = ChainIds.BASE_MAINNET;
        targets[0] = ChainIds.BASE_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        (bytes32 hookSalt, address hookDeployedTo) = mineDecayMulticurveInitializer(msg.sender, createX);

        bytes32 initializerSalt = generateCreate3Salt(msg.sender, type(DecayMulticurveInitializer).name);
        address initializerDeployedTo =
            computeCreate3Address(computeCreate3GuardedSalt(initializerSalt, msg.sender), createX);

        address hook = ICreateX(createX)
            .deployCreate3(
                hookSalt,
                abi.encodePacked(
                    type(DecayMulticurveInitializerHook).creationCode, abi.encode(poolManager, initializerDeployedTo)
                )
            );

        address initializer = ICreateX(createX)
            .deployCreate3(
                initializerSalt,
                abi.encodePacked(type(DecayMulticurveInitializer).creationCode, abi.encode(airlock, poolManager, hook))
            );

        require(hook == hookDeployedTo, "Unexpected Hook deployed address");
        require(initializer == initializerDeployedTo, "Unexpected Initializer deployed address");

        vm.stopBroadcast();
        config.set("decay_multicurve_initializer_hook", hook);
        config.set("decay_multicurve_initializer", initializer);
    }
}
