// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";

struct ScriptData {
    uint256 chainId;
    address weth;
}

/// @dev Deploys Uniswap V2 factory and router contracts. It might happen that these contracts
/// are not present on a recent testnet, so this script can be used to deploy them.
abstract contract DeployUniV2Script is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        require(_scriptData.chainId == block.chainid, "Invalid chainId");
        vm.startBroadcast();

        address uniswapV2Factory = _deployCode(
            abi.encodePacked(
                vm.parseBytes(vm.readFile("./script/utils/uniswapV2Factory.bytecode")), abi.encode(address(0))
            )
        );

        address uniswapV2Router02 = _deployCode(
            abi.encodePacked(
                vm.parseBytes(vm.readFile("./script/utils/uniswapV2Router02.bytecode")),
                abi.encode(uniswapV2Factory, _scriptData.weth)
            )
        );

        vm.stopBroadcast();
    }

    function _deployCode(bytes memory creationCode) internal returns (address deployedTo) {
        assembly {
            deployedTo := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployedTo != address(0), "Deploy failed");
    }
}
