// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { DopplerFactory } from "../src/DopplerFactory.sol";
import { Airlock, ModuleState, WrongModuleState, SetModuleState, WrongInitialSupply } from "src/Airlock.sol";
import { ITokenFactory } from "src/TokenFactory.sol";
import { IGovernanceFactory } from "src/GovernanceFactory.sol";
import { IMigrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { CustomRouter } from "test/shared/CustomRouter.sol";
import { mine, MineParams } from "test/shared/AirlockMiner.sol";
import { Deployers, IPoolManager } from "v4-core/test/utils/Deployers.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import "forge-std/console.sol";

struct Token {
    string name;
    string symbol;
    uint256 totalSupply;
}

struct Hook {
    uint256 endTime;
    uint256 epochLength;
    uint256 gamma;
    uint256 maxProceeds;
    uint256 minProceeds;
    uint256 numPdSlugs;
    uint256 numTokensToSell;
    uint256 startTime;
}

struct Pool {
    uint256 endTick;
    uint256 fee;
    uint256 startTick;
    uint256 tickSpacing;
}

contract DeployDoppler is Script, Deployers {
    Airlock airlock;
    ITokenFactory tokenFactory;
    DopplerFactory factory;
    IGovernanceFactory governanceFactory;
    IMigrator migrator;

    function setUp() public { }

    address constant uniRouterV2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant uniFactoryV2 = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    string public constant ENV_PRIVATE_KEY = "PRIVATE_KEY";

    function run() public {
        uint256 pk = vm.envUint(ENV_PRIVATE_KEY);
        vm.startBroadcast(pk);

        vm.addr(pk);

        airlock = Airlock(payable(vm.envAddress("AIRLOCK")));
        tokenFactory = ITokenFactory(vm.envAddress("TOKEN_FACTORY"));
        governanceFactory = IGovernanceFactory(vm.envAddress("GOVERNANCE_FACTORY"));
        migrator = IMigrator(vm.envAddress("MIGRATOR"));
        factory = DopplerFactory(vm.envAddress("DOPPLER_FACTORY"));
        manager = IPoolManager(vm.envAddress("MANAGER"));

        if (
            vm.envAddress("TOKEN_FACTORY") == address(0) || vm.envAddress("GOVERNANCE_FACTORY") == address(0)
                || vm.envAddress("MIGRATOR") == address(0) || vm.envAddress("DOPPLER_FACTORY") == address(0)
                || vm.envAddress("MANAGER") == address(0)
        ) {
            revert("Missing environment variables");
        }

        (MineParams memory params, Token memory token, Hook memory hook, Pool memory pool) = _getMineParams();
        (bytes32 salt, address hookAddress, address tokenAddress) =
            mine(address(tokenFactory), address(factory), params);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddress),
            fee: uint24(pool.fee),
            tickSpacing: int24(uint24(pool.tickSpacing)),
            hooks: IHooks(hookAddress)
        });

        bytes memory hookFactoryData = abi.encode(
            params.minimumProceeds,
            params.maximumProceeds,
            params.startingTime,
            params.endingTime,
            params.minTick,
            params.maxTick,
            params.epochLength,
            params.gamma,
            false,
            params.numPDSlugs,
            params.airlock
        );

        console.logBytes(hookFactoryData);

        console.logBytes32(salt);

        try airlock.create(
            params.name,
            params.symbol,
            params.initialSupply,
            params.numTokensToSell,
            poolKey,
            new address[](0),
            new uint256[](0),
            tokenFactory,
            new bytes(0),
            governanceFactory,
            new bytes(0),
            factory,
            hookFactoryData,
            migrator,
            salt
        ) {
            console2.log("Create succeeded");
        } catch Error(string memory reason) {
            console2.log("Create failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console2.log("Create failed with low-level error");
            console2.logBytes(lowLevelData);
        }

        vm.stopBroadcast();
    }

    function _getMineParams()
        public
        view
        returns (MineParams memory params, Token memory token, Hook memory hook, Pool memory pool)
    {
        string memory root = vm.projectRoot();

        string memory tokenPath = string.concat(root, "/script/config/token.toml");
        string memory tokenTOML = vm.readFile(tokenPath);
        bytes memory tokenData = vm.parseToml(tokenTOML);
        token = abi.decode(tokenData, (Token));

        string memory poolPath = string.concat(root, "/script/config/pool.toml");
        string memory poolTOML = vm.readFile(poolPath);
        bytes memory poolData = vm.parseToml(poolTOML);
        pool = abi.decode(poolData, (Pool));

        string memory hookPath = string.concat(root, "/script/config/hook.toml");
        string memory hookTOML = vm.readFile(hookPath);
        bytes memory hookData = vm.parseToml(hookTOML);
        hook = abi.decode(hookData, (Hook));

        params = MineParams({
            poolManager: address(manager),
            numTokensToSell: hook.numTokensToSell,
            minTick: int24(uint24(pool.startTick)),
            maxTick: int24(uint24(pool.endTick)),
            airlock: address(airlock),
            name: token.name,
            symbol: token.symbol,
            initialSupply: token.totalSupply,
            numeraire: address(0), // Using ETH
            startingTime: block.timestamp + hook.startTime * 1 days,
            endingTime: block.timestamp + hook.endTime * 1 days,
            minimumProceeds: hook.minProceeds,
            maximumProceeds: hook.maxProceeds,
            epochLength: hook.epochLength,
            gamma: int24(uint24(hook.gamma)),
            numPDSlugs: hook.numPdSlugs
        });
    }
}
