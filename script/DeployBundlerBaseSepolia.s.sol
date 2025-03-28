// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { Airlock } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";

contract DeployBundlerBaseSepoliaScript is Script {
    function run() public {
        Airlock airlock = Airlock(payable(0xa24E35a5d71d02a59b41E7c93567626302da1958));
        UniversalRouter router = UniversalRouter(payable(0x492E6456D9528771018DeB9E87ef7750EF184104));
        IQuoterV2 quoter = IQuoterV2(0xC5290058841028F1614F3A6F0F5816cAd0df5E27);

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
