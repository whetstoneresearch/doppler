// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { WETH } from "@solady/tokens/WETH.sol";

contract DeployUniswapScript is Script {
    string public constant ENV_PRIVATE_KEY = "PRIVATE_KEY";

    function run() public {
        uint256 pk = vm.envUint(ENV_PRIVATE_KEY);
        vm.startBroadcast(pk);

        address account = vm.addr(pk);
        console2.log("account", account);

        address uniswapV2Factory = _deployCode(
            abi.encodePacked(
                vm.parseBytes(vm.readFile("./script/utils/uniswapV2Factory.bytecode")), abi.encode(address(0))
            )
        );

        console2.log("uniswapV2Factory", uniswapV2Factory);

        address weth = address(new WETH());

        address uniswapV2Router02 = _deployCode(
            abi.encodePacked(
                vm.parseBytes(vm.readFile("./script/utils/uniswapV2Router02.bytecode")),
                abi.encode(uniswapV2Factory, weth)
            )
        );

        console2.log("uniswapV2Router02", uniswapV2Router02);

        address uniswapV3Factory =
            _deployCode(abi.encodePacked(vm.parseBytes(vm.readFile("./script/utils/uniswapV3Factory.bytecode"))));

        console2.log("uniswapV3Factory", uniswapV3Factory);

        vm.stopBroadcast();
    }

    function _deployCode(
        bytes memory creationCode
    ) internal returns (address deployedTo) {
        assembly {
            deployedTo := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployedTo != address(0), "Deploy failed");
    }
}
