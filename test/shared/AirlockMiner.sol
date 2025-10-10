// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { UniswapV4Initializer } from "src/UniswapV4Initializer.sol";
import { DERC20 } from "src/DERC20.sol";
import { Doppler } from "src/Doppler.sol";
import { UniswapV4Initializer } from "src/UniswapV4Initializer.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";

// mask to slice out the bottom 14 bit of the address
uint160 constant FLAG_MASK = 0x3FFF;

// Maximum number of iterations to find a salt, avoid infinite loops
uint256 constant MAX_LOOP = 100_000;

uint160 constant DOPPLER_HOOK_FLAGS = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
);

uint160 constant MIGRATOR_HOOK_FLAGS =
    uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

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

struct MineV4MigratorHookParams {
    address poolManager;
    address migrator;
    address hookDeployer;
}

function mineV4MigratorHook(
    MineV4MigratorHookParams memory params
) view returns (bytes32, address) {
    bytes32 migratorHookInitHash = keccak256(
        abi.encodePacked(type(UniswapV4MigratorHook).creationCode, abi.encode(params.poolManager, params.migrator))
    );

    for (uint256 salt; salt < 200_000; ++salt) {
        address hook = computeCreate2Address(bytes32(salt), migratorHookInitHash, address(params.hookDeployer));
        if (uint160(hook) & FLAG_MASK == MIGRATOR_HOOK_FLAGS && hook.code.length == 0) {
            return (bytes32(salt), hook);
        }
    }
    revert("AirlockMiner: could not find salt");
}

function mineV4MulticurveHook(
    MineV4MigratorHookParams memory params
) view returns (bytes32, address) {
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
            uint160(hook) & FLAG_MASK
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

function mineV4ScheduledMulticurveHook(
    MineV4MigratorHookParams memory params
) view returns (bytes32, address) {
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
            uint160(hook) & FLAG_MASK
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

function mineV4(
    MineV4Params memory params
) view returns (bytes32, address, address) {
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
            uint160(hook) & FLAG_MASK == DOPPLER_HOOK_FLAGS && hook.code.length == 0
                && ((isToken0 && asset < params.numeraire) || (!isToken0 && asset > params.numeraire))
        ) {
            return (bytes32(salt), hook, asset);
        }
    }

    revert("AirlockMiner: could not find salt");
}

function computeCreate2Address(
    bytes32 salt,
    bytes32 initCodeHash,
    address deployer
) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
}

// UNCOMMENT AT YOUR OWN RISK
// CAUSES COMPILE TIME YUL EXCEPTION
// contract AirlockMinerTest is Test {

//     function test_mine_works() public view {
//         (bytes32 salt, address hook, address token) = mineV4(
//             address(airlock),
//             address(manager),
//             1e27,
//             1e27,
//             address(0),
//             ITokenFactory(address(0xfac)),
//             abi.encode("Test", "TST", 1e27, 0, new address[](0), new uint256[](0)),
//             initializer,
//             abi.encode(address(0x44444), 0, 0, 0, 0, 0, int24(0), int24(0), 0, int24(0), false, 0)
//         );

//         console.log("salt: %s", uint256(salt));
//         console.log("hook: %s", hook);
//         console.log("token: %s", token);
//     }
// }
