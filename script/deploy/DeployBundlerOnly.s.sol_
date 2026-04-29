// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { Airlock } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { IV4Quoter } from "@v4-periphery/interfaces/IV4Quoter.sol";

/// @notice Deploys only the Bundler contract, using environment variables for dependencies
contract DeployBundlerOnly is Script {
    struct BundlerConfig {
        address payable airlock;
        address universalRouter;
        address quoterV2;
        address quoterV4;
    }

    function run() public {
        BundlerConfig memory config = _readConfig();

        vm.startBroadcast();
        Bundler bundler = new Bundler(
            Airlock(config.airlock),
            UniversalRouter(payable(config.universalRouter)),
            IQuoterV2(config.quoterV2),
            IV4Quoter(config.quoterV4)
        );
        vm.stopBroadcast();

        console.log("Bundler deployed at %s", address(bundler));
    }

    function _readConfig() internal view returns (BundlerConfig memory config) {
        if (block.chainid == ChainIds.BASE_SEPOLIA) {
            // Base Sepolia deployment wiring
            config = BundlerConfig({
                airlock: payable(0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e),
                universalRouter: 0x492E6456D9528771018DeB9E87ef7750EF184104,
                quoterV2: 0xC5290058841028F1614F3A6F0F5816cAd0df5E27,
                quoterV4: 0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa
            });
        } else {
            revert("Unsupported chain");
        }
    }
}
