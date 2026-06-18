// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

contract Versions {
    // --- Core ---
    uint8 public constant AIRLOCK_MULTISIG_VERSION = 0;
    uint8 public constant AIRLOCK_VERSION = 0;
    uint8 public constant BUNDLER_VERSION = 0;
    uint8 public constant TOP_UP_DISTRIBUTOR_VERSION = 0;
    // --- Lockers ---
    uint8 public constant STREAMABLE_FEES_LOCKER_VERSION = 0;
    // UniswapV2Locker is deployed by UniswapV2MigratorSplit
    // --- Token factories ---
    uint8 public constant DOPPLER_ERC20_V1_FACTORY_VERSION = 0;
    uint8 public constant DOPPLER_DN404_FACTORY_VERSION = 0;
    // --- Governance factories ---
    uint8 public constant GOVERNANCE_FACTORY_VERSION = 0;
    uint8 public constant LAUNCHPAD_GOVERNANCE_FACTORY_VERSION = 0;
    uint8 public constant NO_OP_GOVERNANCE_FACTORY_VERSION = 0;
    // --- Initializers ---
    uint8 public constant STATIC_INITIALIZER_VERSION = 0; // LockableUniswapV3Initializer
    uint8 public constant DYNAMIC_INITIALIZER_VERSION = 0; // UniswapV4Initializer
    uint8 public constant MULTICURVE_INITIALIZER_VERSION = 0; // DopplerHookInitializer
    // --- Migrators ---
    uint8 public constant DOPPLER_HOOK_MIGRATOR_VERSION = 0;
    uint8 public constant UNISWAP_V2_MIGRATOR_SPLIT_VERSION = 0;
    uint8 public constant NO_OP_MIGRATOR_VERSION = 0;
    // --- Doppler Hooks ---
    uint8 public constant REHYPE_DOPPLER_HOOK_INITIALIZER_VERSION = 0;
    uint8 public constant REHYPE_DOPPLER_HOOK_MIGRATOR_VERSION = 0;
    uint8 public constant SWAP_RESTRICTOR_DOPPLER_HOOK_VERSION = 0;
    // --- Other ---
    uint8 public constant DOPPLER_LENS_QUOTER_VERSION = 0;
}
