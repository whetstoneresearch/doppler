pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

import {InvalidTime, SwapBelowRange} from "src/Doppler.sol";
import {BaseTest} from "test/shared/BaseTest.sol";
import {Position} from "../../src/Doppler.sol";

contract ReceiveTest is BaseTest {
    function test_receive() public {
        payable(address(hook)).transfer(1 ether);
    }
}
