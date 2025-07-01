// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { BasicMultisig } from "test/shared/BasicMultisig.sol";

contract DeployBasicMultisigScript is Script {
    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        address[] memory signers = new address[](1);
        signers[0] = msg.sender;

        BasicMultisig multisig = new BasicMultisig(signers);

        vm.stopBroadcast();
    }
}
