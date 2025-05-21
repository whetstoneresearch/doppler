// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
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
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { Bundler } from "src/Bundler.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";

struct ScriptData {
    bool deployBundler;
    bool deployLens;
    string explorerUrl;
    address poolManager;
    address protocolOwner;
    address quoterV2;
    address uniswapV2Factory;
    address uniswapV2Router02;
    address uniswapV3Factory;
    address universalRouter;
    address stateView;
}

abstract contract DeployScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        (
            Airlock airlock,
            TokenFactory tokenFactory,
            UniswapV3Initializer uniswapV3Initializer,
            UniswapV4Initializer uniswapV4Initializer,
            GovernanceFactory governanceFactory,
            UniswapV2Migrator uniswapV2Migrator,
            DopplerDeployer dopplerDeployer
        ) = _deployDoppler(_scriptData);

        console.log(unicode"✨ Contracts were successfully deployed!");

        string memory log = string.concat(
            "#  ",
            vm.toString(block.chainid),
            "\n",
            "| Contract | Address |\n",
            "|---|---|\n",
            "| Airlock | ",
            _toMarkdownLink(_scriptData.explorerUrl, address(airlock)),
            " |\n",
            "| TokenFactory | ",
            _toMarkdownLink(_scriptData.explorerUrl, address(tokenFactory)),
            " |\n",
            "| UniswapV3Initializer | ",
            _toMarkdownLink(_scriptData.explorerUrl, address(uniswapV3Initializer)),
            " |\n",
            "| UniswapV4Initializer | ",
            _toMarkdownLink(_scriptData.explorerUrl, address(uniswapV4Initializer)),
            " |\n",
            "| DopplerDeployer | ",
            _toMarkdownLink(_scriptData.explorerUrl, address(dopplerDeployer)),
            " |\n",
            "| GovernanceFactory | ",
            _toMarkdownLink(_scriptData.explorerUrl, address(governanceFactory)),
            " |\n",
            "| UniswapV2LiquidityMigrator | ",
            _toMarkdownLink(_scriptData.explorerUrl, address(uniswapV2Migrator)),
            " |\n"
        );

        if (_scriptData.deployBundler) {
            Bundler bundler = _deployBundler(_scriptData, airlock);
            log = string.concat(log, "| Bundler | ", _toMarkdownLink(_scriptData.explorerUrl, address(bundler)), " |\n");
        }

        if (_scriptData.deployLens) {
            DopplerLensQuoter lens = _deployLens(_scriptData);
            log = string.concat(log, "| Lens | ", _toMarkdownLink(_scriptData.explorerUrl, address(lens)), " |\n");
        }

        vm.writeFile(string.concat("./deployments/", vm.toString(block.chainid), ".md"), log);

        vm.stopBroadcast();
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
            UniswapV2Migrator uniswapV2LiquidityMigrator,
            DopplerDeployer dopplerDeployer
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

        dopplerDeployer = new DopplerDeployer(IPoolManager(scriptData.poolManager));
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

    function _deployLens(
        ScriptData memory scriptData
    ) internal returns (DopplerLensQuoter lens) {
        require(scriptData.poolManager != address(0), "Cannot find PoolManager address!");
        require(scriptData.stateView != address(0), "Cannot find StateView address!");
        lens = new DopplerLensQuoter(IPoolManager(scriptData.poolManager), IStateView(scriptData.stateView));
    }

    function _toMarkdownLink(
        string memory explorerUrl,
        address contractAddress
    ) internal pure returns (string memory) {
        return string.concat("[", vm.toString(contractAddress), "](", explorerUrl, vm.toString(contractAddress), ")");
    }
}
