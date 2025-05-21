// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { WETH } from "@solady/tokens/WETH.sol";
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

struct Addresses {
    address uniswapV2Factory;
    address uniswapV2Router02;
    address uniswapV3Factory;
    address weth;
}

contract DeployTestnetScript is Script {
    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        // Let's check if we have any addresses for the Uniswap contracts
        string memory path = "./script/legacy/addresses.toml";
        string memory raw = vm.readFile(path);
        bool exists = vm.keyExistsToml(raw, string.concat(".", vm.toString(block.chainid)));

        Addresses memory addresses;

        if (exists) {
            bytes memory data = vm.parseToml(raw, string.concat(".", vm.toString(block.chainid)));
            addresses = abi.decode(data, (Addresses));
        }

        addresses = _validateOrDeployUniswap(addresses);

        (
            address airlock,
            address tokenFactory,
            address uniswapV3Initializer,
            address governanceFactory,
            address uniswapV2LiquidityMigrator
        ) = _deployDoppler(addresses);

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
        console.log("| UniswapV2Factory           | %s |", addresses.uniswapV2Factory);
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| UniswapV2Router02          | %s |", addresses.uniswapV2Router02);
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| UniswapV3Factory           | %s |", addresses.uniswapV3Factory);
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| WETH                       | %s |", IUniswapV2Router02(addresses.uniswapV2Router02).WETH());
        console.log("+----------------------------+--------------------------------------------+");

        vm.stopBroadcast();
    }

    function _deployDoppler(
        Addresses memory addresses
    ) internal returns (address, address, address, address, address) {
        // Let's check that a valid protocol owner is set
        address owner = vm.envOr("PROTOCOL_OWNER", address(0));
        require(owner != address(0), "PROTOCOL_OWNER not set! Please edit your .env file.");
        console.log(unicode"👑 PROTOCOL_OWNER set as %s", owner);

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

        return (
            address(airlock),
            address(tokenFactory),
            address(uniswapV3Initializer),
            address(governanceFactory),
            address(uniswapV2LiquidityMigrator)
        );
    }

    function _validateOrDeployUniswap(
        Addresses memory addresses
    ) internal returns (Addresses memory deployedAddresses) {
        console.log(addresses.weth);

        if (addresses.weth == address(0)) {
            deployedAddresses.weth = address(new WETH());
        } else {
            deployedAddresses.weth = addresses.weth;
        }

        if (addresses.uniswapV2Factory == address(0)) {
            deployedAddresses.uniswapV2Factory = _deployCode(
                abi.encodePacked(
                    vm.parseBytes(vm.readFile("./script/utils/uniswapV2Factory.bytecode")), abi.encode(address(0))
                )
            );
        } else {
            deployedAddresses.uniswapV2Factory = addresses.uniswapV2Factory;
        }

        if (
            addresses.uniswapV2Router02 == address(0) || addresses.weth != deployedAddresses.weth
                || addresses.uniswapV2Factory != deployedAddresses.uniswapV2Factory
        ) {
            deployedAddresses.uniswapV2Router02 = _deployCode(
                abi.encodePacked(
                    vm.parseBytes(vm.readFile("./script/utils/uniswapV2Router02.bytecode")),
                    abi.encode(deployedAddresses.uniswapV2Factory, deployedAddresses.weth)
                )
            );
        } else {
            deployedAddresses.uniswapV2Router02 = addresses.uniswapV2Router02;
        }

        if (addresses.uniswapV3Factory == address(0)) {
            deployedAddresses.uniswapV3Factory =
                _deployCode(abi.encodePacked(vm.parseBytes(vm.readFile("./script/utils/uniswapV3Factory.bytecode"))));
        } else {
            deployedAddresses.uniswapV3Factory = addresses.uniswapV3Factory;
        }
    }

    function _deployCode(
        bytes memory creationCode
    ) internal returns (address deployedTo) {
        assembly {
            deployedTo := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployedTo != address(0), "Deploy failed");
    }
}
