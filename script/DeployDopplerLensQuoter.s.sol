// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Config } from "forge-std/Config.sol";
import { TypeKind, Variable } from "forge-std/LibVariable.sol";
import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { LibString } from "solady/utils/LibString.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";

contract DeployDopplerLensQuoterScript is Script, Config {
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
        address stateView = config.get("uniswap_v4_state_view").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(DopplerLensQuoter).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address dopplerLensQuoter = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(DopplerLensQuoter).creationCode, abi.encode(poolManager, stateView))
            );
        require(dopplerLensQuoter == expectedAddress, "Unexpected deployed address");
        vm.stopBroadcast();

        // Only set the config if a broadcast has occurred
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) config.set("doppler_lens_quoter", dopplerLensQuoter);
        console.log(
            "DopplerLensQuoter was deployed to",
            LibString.toHexString(uint256(uint160(dopplerLensQuoter))),
            "on chain ID",
            LibString.toString(chainId)
        );
    }
}
