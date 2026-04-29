// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { LibString } from "solady/utils/LibString.sol";
import { RehypeDopplerHookMigrator } from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";

contract DeployRehypeHookMigratorScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](1);
        //targets[0] = ChainIds.ETH_MAINNET;
        targets[0] = ChainIds.MONAD_MAINNET;
        //targets[2] = ChainIds.BASE_MAINNET;
        //targets[3] = ChainIds.BASE_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            vm.selectFork(forkOf[chainId]);
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        address createX = config.get("create_x").toAddress();
        address migrator = config.get("doppler_hook_migrator").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, "RehypeDopplerHookMigrator-5");
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), address(createX));

        address rehypeDopplerHookMigrator = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(RehypeDopplerHookMigrator).creationCode, abi.encode(migrator, poolManager))
            );
        require(rehypeDopplerHookMigrator == expectedAddress, "Unexpected deployed address");
        vm.stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            config.set("rehype_doppler_hook_migrator", rehypeDopplerHookMigrator);
            config.set("quoter", address(RehypeDopplerHookMigrator(payable(rehypeDopplerHookMigrator)).quoter()));
        }
        console.log(
            "RehypeDopplerHookMigrator was deployed to",
            LibString.toHexString(uint256(uint160(rehypeDopplerHookMigrator))),
            "on chain ID",
            LibString.toString(chainId)
        );
    }
}

