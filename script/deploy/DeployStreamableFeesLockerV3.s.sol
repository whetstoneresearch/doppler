// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ICreateX } from "createx/ICreateX.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { LibString } from "solady/utils/LibString.sol";
import { StreamableFeesLockerV3 } from "src/lockers/StreamableFeesLockerV3.sol";

contract DeployStreamableFeesLockerV3Script is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](4);
        targets[0] = ChainIds.ETH_MAINNET;
        targets[1] = ChainIds.MONAD_MAINNET;
        targets[2] = ChainIds.BASE_MAINNET;
        targets[3] = ChainIds.BASE_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            vm.selectFork(forkOf[chainId]);
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();
        address positionManager = config.get("uniswap_v4_position_manager").toAddress();
        address owner = config.get("airlock_multisig").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(StreamableFeesLockerV3).name);
        address deployedTo = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address lockerV3 = ICreateX(createX)
            .deployCreate3(
                salt,
                abi.encodePacked(
                    type(StreamableFeesLockerV3).creationCode, abi.encode(poolManager, positionManager, owner)
                )
            );

        require(lockerV3 == deployedTo, "Unexpected deployed address");

        vm.stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            config.set("streamable_fees_locker_v3", lockerV3);
        }

        console.log(
            "StreamableFeesLockerV3 was deployed to",
            LibString.toHexString(uint256(uint160(lockerV3))),
            "on chain ID",
            LibString.toString(chainId)
        );
    }
}
