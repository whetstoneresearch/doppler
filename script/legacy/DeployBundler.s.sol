// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { IV4Quoter } from "@v4-periphery/interfaces/IV4Quoter.sol";
import { Airlock } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";

struct DeployBundlerScriptData {
    address airlock;
    address quoterV2;
    address quoterV4;
    address router;
}

contract DeployBundlerScript is Script {
    function _deployBundler(Airlock airlock, UniversalRouter router, IQuoterV2 quoter, IV4Quoter quoterV4)
        internal
        returns (Bundler)
    {
        vm.startBroadcast();
        Bundler bundler = new Bundler(airlock, router, quoter, quoterV4);
        vm.stopBroadcast();
        return bundler;
    }

    function run() public {
        console.log(unicode"🚀 Deploying Bundler on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        // Let's check if we have the script data for this chain
        string memory path = "./script/legacy/addresses.toml";
        string memory raw = vm.readFile(path);
        bool exists = vm.keyExistsToml(raw, string.concat(".", vm.toString(block.chainid)));
        require(exists, string.concat("Missing script data for chain id", vm.toString(block.chainid)));

        bytes memory data = vm.parseToml(raw, string.concat(".", vm.toString(block.chainid)));
        DeployBundlerScriptData memory scriptData = abi.decode(data, (DeployBundlerScriptData));

        _deployBundler(
            Airlock(payable(scriptData.airlock)),
            UniversalRouter(payable(scriptData.router)),
            IQuoterV2(scriptData.quoterV2),
            IV4Quoter(scriptData.quoterV4)
        );

        /*
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Bundler                    | %s |", address(bundler));
        console.log("+----------------------------+--------------------------------------------+");
        */
    }
}
