// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.7 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract ForkDebugTest is Test {
    address SENDER = vm.envOr("DEBUG_CALL_SENDER", address(0));
    address RECEIVER = vm.envOr("DEBUG_CALL_RECEIVER", address(0));

    bytes error_calldata = vm.envOr("DEBUG_CALL_CALLDATA", new bytes(0));

    string empty;
    string RPC_URL = vm.envOr("DEBUG_RPC_URL", empty);

    bool enabled = false;

    function setUp() public {
        if (RECEIVER == address(0) || SENDER == address(0) || error_calldata.length == 0 || bytes(RPC_URL).length == 0)
        {
            enabled = false;
            console.log("ForkDebugTest is not enabled due to missing environment variables.");
            vm.skip(true);
        } else {
            vm.createSelectFork(RPC_URL);
            enabled = true;
            console.log("ForkDebugTest is enabled");
        }
    }

    function testDebug() public {
        if (!enabled) {
            console.log("Skipping testDebug because ForkDebugTest is not enabled.");
            return;
        }
        vm.startPrank(SENDER);
        (bool success,) = RECEIVER.call(error_calldata);
        require(success, "ForkDebugTest call failed");
        vm.stopPrank();
    }
}
