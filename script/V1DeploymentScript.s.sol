// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IUniswapV2Router02 } from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Router02.sol";
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
import { InitData, UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { DERC20 } from "src/DERC20.sol";

struct Addresses {
    address uniswapV2Factory;
    address uniswapV2Router02;
    address uniswapV3Factory;
}

contract V1DeploymentScript is Script {
    function run() public {
        // Let's validate that we have the correct addresses for the chain we're targeting
        string memory path = "./script/addresses.json";
        string memory json = vm.readFile(path);
        bool exists = vm.keyExistsJson(json, string.concat(".", vm.toString(block.chainid)));
        require(exists, string.concat("Missing Uniswap addresses for chain with id ", vm.toString(block.chainid)));
        bytes memory data = vm.parseJson(json, string.concat(".", vm.toString(block.chainid)));
        Addresses memory addresses = abi.decode(data, (Addresses));

        // Let's check that a valid protocol owner is set
        address owner = vm.envOr("PROTOCOL_OWNER", address(0));
        require(owner != address(0), "PROTOCOL_OWNER not set! Please edit your .env file.");
        console.log(unicode"👑 PROTOCOL_OWNER set as %s", owner);

        vm.startBroadcast();
        console.log(unicode"🚀 Deploying contracts with sender %s...", msg.sender);

        // Owner of the protocol is first set as the deployer to allow the whitelisting of modules,
        // ownership is then transferred to the address defined as the PROTOCOL_OWNER
        Airlock airlock = new Airlock(msg.sender);
        TokenFactory tokenFactory = new TokenFactory(address(airlock));
        UniswapV3Initializer uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(addresses.uniswapV3Factory));
        GovernanceFactory governanceFactory = new GovernanceFactory(address(airlock));
        UniswapV2Migrator uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(addresses.uniswapV2Factory),
            IUniswapV2Router02(addresses.uniswapV2Router02),
            owner
        );

        // Whitelisting the initial modules
        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV3Initializer);
        modules[2] = address(governanceFactory);
        modules[3] = address(uniswapV2LiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.LiquidityMigrator;

        airlock.setModuleState(modules, states);

        // Transfer ownership to the actual PROTOCOL_OWNER
        airlock.transferOwnership(owner);

        console.log(unicode"✨ Contracts were successfully deployed:");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Airlock                    | %s |", address(airlock));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| TokenFactory               | %s |", address(tokenFactory));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| UniswapV3Initializer       | %s |", address(uniswapV3Initializer));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| GovernanceFactory          | %s |", address(governanceFactory));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| UniswapV2LiquidityMigrator | %s |", address(uniswapV2LiquidityMigrator));
        console.log("+----------------------------+--------------------------------------------+");

        // Now it's time to deploy a first token
        _deployToken(
            airlock,
            tokenFactory,
            governanceFactory,
            uniswapV3Initializer,
            uniswapV2LiquidityMigrator,
            IUniswapV2Router02(addresses.uniswapV2Router02).WETH()
        );

        vm.stopBroadcast();

        // Some checks to ensure that the deployment was successful
        for (uint256 i; i < modules.length; i++) {
            require(airlock.getModuleState(modules[i]) == states[i], "Module state not set correctly");
        }
        require(address(tokenFactory.airlock()) == address(airlock), "TokenFactory not set correctly");
        require(address(uniswapV3Initializer.airlock()) == address(airlock), "UniswapV3Initializer not set correctly");
        require(address(governanceFactory.airlock()) == address(airlock), "GovernanceFactory not set correctly");
        require(
            address(uniswapV2LiquidityMigrator.airlock()) == address(airlock),
            "UniswapV2LiquidityMigrator not set correctly"
        );
        require(airlock.owner() == owner, "Ownership not transferred to PROTOCOL_OWNER");
    }

    function _deployToken(
        Airlock airlock,
        ITokenFactory tokenFactory,
        IGovernanceFactory governanceFactory,
        IPoolInitializer poolInitializer,
        ILiquidityMigrator liquidityMigrator,
        address weth
    ) internal {
        int24 DEFAULT_LOWER_TICK = 167_520;
        int24 DEFAULT_UPPER_TICK = 200_040;
        uint256 DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.9 ether;

        bool isToken0;
        uint256 initialSupply = 1_000_000_000 ether;
        string memory name = "a";
        string memory symbol = "a";
        string memory tokenURI = "ipfs://QmPXxsEGfHHnCa8VuPoMS7n1pAhJVw1BnnfSx83sioE65y";
        bytes memory governanceData = abi.encode(name, 7200, 50_400, initialSupply / 1000);
        bytes memory tokenFactoryData = abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), tokenURI);

        // Compute the asset address that will be created
        bytes32 salt;

        bytes memory creationCode = type(DERC20).creationCode;
        bytes memory create2Args = abi.encode(
            name,
            symbol,
            initialSupply,
            address(airlock),
            address(airlock),
            0,
            0,
            new address[](0),
            new uint256[](0),
            tokenURI
        );
        address predictedAsset = vm.computeCreate2Address(
            salt, keccak256(abi.encodePacked(creationCode, create2Args)), address(tokenFactory)
        );

        isToken0 = predictedAsset < address(weth);

        int24 tickLower = isToken0 ? -DEFAULT_UPPER_TICK : DEFAULT_LOWER_TICK;
        int24 tickUpper = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_UPPER_TICK;

        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: uint24(vm.envOr("V3_FEE", uint256(3000))),
                tickLower: tickLower,
                tickUpper: tickUpper,
                numPositions: 10,
                maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD
            })
        );

        (address asset,,,,) = airlock.create(
            CreateParams(
                initialSupply,
                900_000_000 ether,
                weth,
                tokenFactory,
                tokenFactoryData,
                governanceFactory,
                governanceData,
                poolInitializer,
                poolInitializerData,
                liquidityMigrator,
                new bytes(0),
                address(0),
                salt
            )
        );

        console.log("| Asset Token                | %s |", asset);
        console.log("+----------------------------+--------------------------------------------+");

        require(asset == predictedAsset, "Predicted asset address doesn't match actual");
    }
}
