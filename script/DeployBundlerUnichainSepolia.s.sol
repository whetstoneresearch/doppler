// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { Airlock } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";

contract DeployBundlerUnichainSepoliaScript is Script {
    function run() public {
        Airlock airlock = Airlock(payable(0x77EbfBAE15AD200758E9E2E61597c0B07d731254));
        UniversalRouter router = UniversalRouter(payable(0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D));
        IQuoterV2 quoter = IQuoterV2(0x6Dd37329A1A225a6Fca658265D460423DCafBF89);

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
