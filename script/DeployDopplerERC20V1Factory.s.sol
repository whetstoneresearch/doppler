/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { LibString } from "solady/utils/LibString.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";

error UnexpectedAddress();

contract DeployDopplerERC20V1FactoryScript is Script, Config {
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

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(DopplerERC20V1Factory).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address dopplerERC20V1Factory = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(DopplerERC20V1Factory).creationCode, abi.encode(airlock)));
        require(dopplerERC20V1Factory == expectedAddress, UnexpectedAddress());
        vm.stopBroadcast();

        address implementation = DopplerERC20V1Factory(dopplerERC20V1Factory).IMPLEMENTATION();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            config.set("doppler_erc20_v1_factory", dopplerERC20V1Factory);
            config.set("doppler_erc20_v1_implementation", implementation);
        }
        console.log(
            "DopplerERC20V1Factory was deployed to",
            LibString.toHexString(uint256(uint160(dopplerERC20V1Factory))),
            "on chain ID",
            LibString.toString(chainId)
        );
        console.log(
            "DopplerERC20V1 implementation was deployed to",
            LibString.toHexString(uint256(uint160(implementation))),
            "on chain ID",
            LibString.toString(chainId)
        );
    }
}
