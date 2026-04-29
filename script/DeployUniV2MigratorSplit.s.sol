// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { TypeKind, Variable } from "forge-std/LibVariable.sol";
import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { LibString } from "solady/utils/LibString.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV2MigratorSplit } from "src/migrators/UniswapV2MigratorSplit.sol";

contract DeployUniV2MigratorSplitScript is Script, Config {
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
        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address uniswapV2Factory = config.get("uniswap_v2_factory").toAddress();
        address topUpDistributor = config.get("top_up_distributor").toAddress();
        address weth = config.get("weth").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(UniswapV2MigratorSplit).name);
        address deployedTo = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address migrator = ICreateX(createX)
            .deployCreate3(
                salt,
                abi.encodePacked(
                    type(UniswapV2MigratorSplit).creationCode,
                    abi.encode(airlock, uniswapV2Factory, topUpDistributor, weth)
                )
            );
        require(migrator == deployedTo, "Unexpected deployed address");
        vm.stopBroadcast();
        address locker = address(UniswapV2MigratorSplit(payable(migrator)).locker());

        // Only set the config if a broadcast has occurred
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            config.set("uniswap_v2_migrator_split", migrator);
            config.set("uniswap_v2_locker", locker);
        }
        console.log(
            "UniswapV2MigratorSplit was deployed to",
            LibString.toHexString(uint256(uint160(migrator))),
            "on chain ID",
            LibString.toString(chainId)
        );
        console.log(
            "UniswapV2Locker was deployed to",
            LibString.toHexString(uint256(uint160(locker))),
            "on chain ID",
            LibString.toString(chainId)
        );
    }
}
