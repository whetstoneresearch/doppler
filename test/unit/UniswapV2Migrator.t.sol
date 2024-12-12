/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { UniswapV2Migrator, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UNISWAP_V2_FACTORY_MAINNET } from "test/shared/Addresses.sol";

contract UniswapV2MigratorTest is Test {
    UniswapV2Migrator public migrator;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        migrator = new UniswapV2Migrator(address(this), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET));
    }
}
