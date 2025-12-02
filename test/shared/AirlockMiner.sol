// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/initializers/UniswapV4MulticurveInitializerHook.sol";
import {
    UniswapV4ScheduledMulticurveInitializerHook
} from "src/initializers/UniswapV4ScheduledMulticurveInitializerHook.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { UniswapV4MigratorHook } from "src/migrators/UniswapV4MigratorHook.sol";
import { DERC20 } from "src/tokens/DERC20.sol";

/* ----------------------------------------------------------------------------------- */
/*                                DopplerHookInitializer                               */
/* ----------------------------------------------------------------------------------- */

uint160 constant DOPPLER_HOOK_INITIALIZER_FLAGS = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_SWAP_FLAG
);

struct MineDopplerHookInitializerParams {
    address airlock;
    address poolManager;
    address deployer;
}

function mineDopplerHookInitializer(MineDopplerHookInitializerParams memory params) view returns (bytes32, address) {
    bytes32 initHash = keccak256(
        abi.encodePacked(type(DopplerHookInitializer).creationCode, abi.encode(params.airlock, params.poolManager))
    );

    for (uint256 salt; salt < 200_000; salt++) {
        address initializer = computeCreate2Address(bytes32(salt), initHash, params.deployer);
        if (
            uint160(initializer) & Hooks.ALL_HOOK_MASK == DOPPLER_HOOK_INITIALIZER_FLAGS && initializer.code.length == 0
        ) {
            return (bytes32(salt), initializer);
        }
    }

    revert("AirlockMiner: could not find salt");
}

/* ---------------------------------------------------------------------------------- */
/*                                UniswapV4MigratorHook                               */
/* ---------------------------------------------------------------------------------- */

uint160 constant MIGRATOR_HOOK_FLAGS =
    uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

struct MineV4MigratorHookParams {
    address poolManager;
    address migrator;
    address hookDeployer;
}

function mineV4MigratorHook(MineV4MigratorHookParams memory params) view returns (bytes32, address) {
    bytes32 migratorHookInitHash = keccak256(
        abi.encodePacked(type(UniswapV4MigratorHook).creationCode, abi.encode(params.poolManager, params.migrator))
    );

    for (uint256 salt; salt < 200_000; ++salt) {
        address hook = computeCreate2Address(bytes32(salt), migratorHookInitHash, address(params.hookDeployer));
        if (uint160(hook) & Hooks.ALL_HOOK_MASK == MIGRATOR_HOOK_FLAGS && hook.code.length == 0) {
            return (bytes32(salt), hook);
        }
    }
    revert("AirlockMiner: could not find salt");
}

/* ----------------------------------------------------------------------------------------------- */
/*                                UniswapV4MulticurveInitializerHook                               */
/* ----------------------------------------------------------------------------------------------- */

function mineV4MulticurveHook(MineV4MigratorHookParams memory params) view returns (bytes32, address) {
    bytes32 multicurveHookInitHash = keccak256(
        abi.encodePacked(
            type(UniswapV4MulticurveInitializerHook).creationCode,
            abi.encode(
                params.poolManager,
                params.migrator // In that case it's the initializer address
            )
        )
    );

    for (uint256 salt; salt < 200_000; ++salt) {
        address hook = computeCreate2Address(bytes32(salt), multicurveHookInitHash, address(params.hookDeployer));
        if (
            uint160(hook) & Hooks.ALL_HOOK_MASK
                    == uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                    ) && hook.code.length == 0
        ) {
            return (bytes32(salt), hook);
        }
    }
    revert("AirlockMiner: could not find salt");
}

/* -------------------------------------------------------------------------------------------------------- */
/*                                UniswapV4ScheduledMulticurveInitializerHook                               */
/* -------------------------------------------------------------------------------------------------------- */

function mineV4ScheduledMulticurveHook(MineV4MigratorHookParams memory params) view returns (bytes32, address) {
    bytes32 multicurveHookInitHash = keccak256(
        abi.encodePacked(
            type(UniswapV4ScheduledMulticurveInitializerHook).creationCode,
            abi.encode(
                params.poolManager,
                params.migrator // In that case it's the initializer address
            )
        )
    );

    for (uint256 salt; salt < 200_000; ++salt) {
        address hook = computeCreate2Address(bytes32(salt), multicurveHookInitHash, address(params.hookDeployer));
        if (
            uint160(hook) & Hooks.ALL_HOOK_MASK
                    == uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    ) && hook.code.length == 0
        ) {
            return (bytes32(salt), hook);
        }
    }
    revert("AirlockMiner: could not find salt");
}

/* -------------------------------------------------------------------- */
/*                                Doppler                               */
/* -------------------------------------------------------------------- */

uint160 constant DOPPLER_HOOK_FLAGS = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
);

struct MineV4Params {
    address airlock;
    address poolManager;
    uint256 initialSupply;
    uint256 numTokensToSell;
    address numeraire;
    ITokenFactory tokenFactory;
    bytes tokenFactoryData;
    UniswapV4Initializer poolInitializer;
    bytes poolInitializerData;
}

function mineV4(MineV4Params memory params) view returns (bytes32, address, address) {
    (
        uint256 minimumProceeds,
        uint256 maximumProceeds,
        uint256 startingTime,
        uint256 endingTime,
        int24 startingTick,
        int24 endingTick,
        uint256 epochLength,
        int24 gamma,
        bool isToken0,
        uint256 numPDSlugs,
        uint24 lpFee,
        int24 tickSpacing
    ) = abi.decode(
        params.poolInitializerData,
        (uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, uint24, int24)
    );

    bytes32 dopplerInitHash = keccak256(
        abi.encodePacked(
            type(Doppler).creationCode,
            abi.encode(
                params.poolManager,
                params.numTokensToSell,
                minimumProceeds,
                maximumProceeds,
                startingTime,
                endingTime,
                startingTick,
                endingTick,
                epochLength,
                gamma,
                isToken0,
                numPDSlugs,
                params.poolInitializer,
                lpFee
            )
        )
    );

    (
        string memory name,
        string memory symbol,
        uint256 yearlyMintCap,
        uint256 vestingDuration,
        address[] memory recipients,
        uint256[] memory amounts,
        string memory tokenURI
    ) = abi.decode(params.tokenFactoryData, (string, string, uint256, uint256, address[], uint256[], string));

    bytes32 tokenInitHash = keccak256(
        abi.encodePacked(
            type(DERC20).creationCode,
            abi.encode(
                name,
                symbol,
                params.initialSupply,
                params.airlock,
                params.airlock,
                yearlyMintCap,
                vestingDuration,
                recipients,
                amounts,
                tokenURI
            )
        )
    );

    address deployer = address(params.poolInitializer.deployer());

    for (uint256 salt; salt < 200_000; ++salt) {
        address hook = computeCreate2Address(bytes32(salt), dopplerInitHash, deployer);
        address asset = computeCreate2Address(bytes32(salt), tokenInitHash, address(params.tokenFactory));

        if (
            uint160(hook) & Hooks.ALL_HOOK_MASK == DOPPLER_HOOK_FLAGS && hook.code.length == 0
                && ((isToken0 && asset < params.numeraire) || (!isToken0 && asset > params.numeraire))
        ) {
            return (bytes32(salt), hook, asset);
        }
    }

    revert("AirlockMiner: could not find salt");
}

function computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
}
