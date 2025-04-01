// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { Airlock } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";

contract DeployBundlerInkScript is Script {
    function run() public {
        Airlock airlock = Airlock(payable(0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12));
        UniversalRouter router = UniversalRouter(payable(0x112908daC86e20e7241B0927479Ea3Bf935d1fa0));
        IQuoterV2 quoter = IQuoterV2(0x96b572D2d880cf2Fa2563651BD23ADE6f5516652);

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
