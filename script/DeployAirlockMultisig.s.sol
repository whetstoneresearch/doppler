// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { Airlock } from "src/Airlock.sol";
import { AirlockMultisig } from "test/shared/AirlockMultisig.sol";

contract DeployAirlockMultisigScript is Script {
    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        address[] memory signers = new address[](1);
        signers[0] = msg.sender;

        try vm.promptAddress("Enter the address of the Airlock contract:") returns (address airlock) {
            vm.startBroadcast();
            AirlockMultisig multisig = new AirlockMultisig(Airlock(payable(airlock)), signers);
            vm.stopBroadcast();
        } catch {
            revert("Airlock contract address is required.");
        }
    }
}
