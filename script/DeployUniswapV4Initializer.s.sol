// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";

contract DeployUniswapV4InitializerScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](2);
        targets[0] = ChainIds.ETH_MAINNET;
        targets[1] = ChainIds.ETH_SEPOLIA;

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
        bytes32 dopplerDeployerSalt = generateCreate3Salt(msg.sender, type(DopplerDeployer).name);
        address expectedDoppledDeployer =
            computeCreate3Address(computeCreate3GuardedSalt(dopplerDeployerSalt, msg.sender), createX);

        address dopplerDeployer = ICreateX(createX)
            .deployCreate3(
                dopplerDeployerSalt, abi.encodePacked(type(DopplerDeployer).creationCode, abi.encode(poolManager))
            );
        require(dopplerDeployer == expectedDoppledDeployer, "Unexpected DopplerDeployer address");

        bytes32 uniswapV4InitializerSalt = generateCreate3Salt(msg.sender, type(UniswapV4Initializer).name);
        address expectedUniswapV4Initializer =
            computeCreate3Address(computeCreate3GuardedSalt(uniswapV4InitializerSalt, msg.sender), createX);

        address uniswapV4Initializer = ICreateX(createX)
            .deployCreate3(
                uniswapV4InitializerSalt,
                abi.encodePacked(
                    type(UniswapV4Initializer).creationCode, abi.encode(airlock, poolManager, dopplerDeployer)
                )
            );
        require(uniswapV4Initializer == expectedUniswapV4Initializer, "Unexpected UniswapV4Initializer address");

        vm.stopBroadcast();
        config.set("uniswap_v4_initializer", uniswapV4Initializer);
        config.set("doppler_deployer", dopplerDeployer);
    }
}
