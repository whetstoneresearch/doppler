// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import {
    Airlock,
    ModuleState,
    CreateParams,
    ITokenFactory,
    IGovernanceFactory,
    IPoolInitializer,
    ILiquidityMigrator
} from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { UniswapV4Initializer, DopplerDeployer, IPoolManager } from "src/UniswapV4Initializer.sol";
import { Bundler } from "src/Bundler.sol";

struct ScriptData {
    bool deployBundler;
    string explorerUrl;
    address poolManager;
    address protocolOwner;
    address quoterV2;
    address uniswapV2Factory;
    address uniswapV2Router02;
    address uniswapV3Factory;
    address universalRouter;
    address weth;
}

contract DeployScript is Script {
    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        // Let's check if we have the script data for this chain
        string memory path = "./script/addresses.toml";
        string memory raw = vm.readFile(path);
        bool exists = vm.keyExistsToml(raw, string.concat(".", vm.toString(block.chainid)));
        require(exists, string.concat("Missing script data for chain id", vm.toString(block.chainid)));

        bytes memory data = vm.parseToml(raw, string.concat(".", vm.toString(block.chainid)));
        ScriptData memory scriptData = abi.decode(data, (ScriptData));

        (
            Airlock airlock,
            TokenFactory tokenFactory,
            UniswapV3Initializer uniswapV3Initializer,
            UniswapV4Initializer uniswapV4Initializer,
            GovernanceFactory governanceFactory,
            UniswapV2Migrator uniswapV2Migrator
        ) = _deployDoppler(scriptData);

        console.log(unicode"✨ Contracts were successfully deployed!");

        string memory log = string.concat(
            "#  ",
            vm.toString(block.chainid),
            "\n",
            "| Contract | Address |\n",
            "|---|---|\n",
            "| Airlock | ",
            _toMarkdownLink(scriptData.explorerUrl, address(airlock)),
            " |\n",
            "| TokenFactory | ",
            _toMarkdownLink(scriptData.explorerUrl, address(tokenFactory)),
            " |\n",
            "| UniswapV3Initializer | ",
            _toMarkdownLink(scriptData.explorerUrl, address(uniswapV3Initializer)),
            " |\n",
            "| UniswapV4Initializer | ",
            _toMarkdownLink(scriptData.explorerUrl, address(uniswapV4Initializer)),
            " |\n",
            "| GovernanceFactory | ",
            _toMarkdownLink(scriptData.explorerUrl, address(governanceFactory)),
            " |\n",
            "| UniswapV2LiquidityMigrator | ",
            _toMarkdownLink(scriptData.explorerUrl, address(uniswapV2Migrator)),
            " |\n"
        );

        if (scriptData.deployBundler) {
            Bundler bundler = _deployBundler(scriptData, airlock);
            log = string.concat(log, "| Bundler | ", _toMarkdownLink(scriptData.explorerUrl, address(bundler)), " |");
        }

        vm.writeFile(string.concat("./deployments/", vm.toString(block.chainid), ".md"), log);

        vm.stopBroadcast();
    }

    function _toMarkdownLink(
        string memory explorerUrl,
        address contractAddress
    ) internal pure returns (string memory) {
        return string.concat("[", vm.toString(contractAddress), "](", explorerUrl, vm.toString(contractAddress), ")");
    }

    function _deployDoppler(
        ScriptData memory scriptData
    )
        internal
        returns (
            Airlock airlock,
            TokenFactory tokenFactory,
            UniswapV3Initializer uniswapV3Initializer,
            UniswapV4Initializer uniswapV4Initializer,
            GovernanceFactory governanceFactory,
            UniswapV2Migrator uniswapV2LiquidityMigrator
        )
    {
        // Let's check that a valid protocol owner is set
        require(scriptData.protocolOwner != address(0), "Protocol owner not set!");
        console.log(unicode"👑 Protocol owner set as %s", scriptData.protocolOwner);

        require(scriptData.uniswapV2Factory != address(0), "Cannot find UniswapV2Factory address!");
        require(scriptData.uniswapV2Router02 != address(0), "Cannot find UniswapV2Router02 address!");
        require(scriptData.uniswapV3Factory != address(0), "Cannot find UniswapV3Factory address!");

        // Owner of the protocol is first set as the deployer to allow the whitelisting of modules,
        // ownership is then transferred to the address defined as the "protocol_owner"
        airlock = new Airlock(msg.sender);
        tokenFactory = new TokenFactory(address(airlock));
        uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(scriptData.uniswapV3Factory));
        governanceFactory = new GovernanceFactory(address(airlock));
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(scriptData.uniswapV2Factory),
            IUniswapV2Router02(scriptData.uniswapV2Router02),
            scriptData.protocolOwner
        );

        DopplerDeployer dopplerDeployer = new DopplerDeployer(IPoolManager(scriptData.poolManager));
        uniswapV4Initializer =
            new UniswapV4Initializer(address(airlock), IPoolManager(scriptData.poolManager), dopplerDeployer);

        // Whitelisting the initial modules
        address[] memory modules = new address[](5);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV3Initializer);
        modules[2] = address(governanceFactory);
        modules[3] = address(uniswapV2LiquidityMigrator);
        modules[4] = address(uniswapV4Initializer);

        ModuleState[] memory states = new ModuleState[](5);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.LiquidityMigrator;
        states[4] = ModuleState.PoolInitializer;

        airlock.setModuleState(modules, states);

        // Transfer ownership to the actual protocol owner
        airlock.transferOwnership(scriptData.protocolOwner);
    }

    function _deployBundler(ScriptData memory scriptData, Airlock airlock) internal returns (Bundler bundler) {
        require(scriptData.universalRouter != address(0), "Cannot find UniversalRouter address!");
        require(scriptData.quoterV2 != address(0), "Cannot find QuoterV2 address!");
        bundler =
            new Bundler(airlock, UniversalRouter(payable(scriptData.universalRouter)), IQuoterV2(scriptData.quoterV2));
    }
}
