// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { Airlock } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";

contract DeployBundlerUnichainScript is Script {
    function run() public {
        Airlock airlock = Airlock(payable(0x77EbfBAE15AD200758E9E2E61597c0B07d731254));
        UniversalRouter router = UniversalRouter(payable(0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3));
        IQuoterV2 quoter = IQuoterV2(0x385A5cf5F83e99f7BB2852b6A19C3538b9FA7658);

        vm.startBroadcast();
        Bundler bundler = new Bundler(airlock, router, quoter);

        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Bundler                    | %s |", address(bundler));
        console.log("+----------------------------+--------------------------------------------+");
        vm.stopBroadcast();
    }
}
