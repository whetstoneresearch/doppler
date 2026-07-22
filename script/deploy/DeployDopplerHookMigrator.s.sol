// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";

uint160 constant DOPPLER_HOOK_MIGRATOR_FLAGS = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
);

abstract contract DeployDopplerHookMigrator is DeployBase {
    function _deployDopplerHookMigrator(DeployContext memory context) internal returns (address dopplerHookMigrator) {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        address topUpDistributor = context.config.get(context.chainId, "top_up_distributor").toAddress();
        address locker = context.config.get(context.chainId, "streamable_fees_locker_v2").toAddress();
        return _deployDopplerHookMigrator(context, airlock, topUpDistributor, locker);
    }

    function _deployDopplerHookMigrator(
        DeployContext memory context,
        address airlock,
        address topUpDistributor,
        address locker
    ) internal returns (address dopplerHookMigrator) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();
        bytes memory initCode = abi.encodePacked(
            type(DopplerHookMigrator).creationCode, abi.encode(airlock, poolManager, locker, topUpDistributor)
        );
        (bytes32 salt, address expected) =
            _mineDopplerHookMigratorSalt(context, airlock, poolManager, locker, topUpDistributor);

        bool alreadyDeployed;
        (dopplerHookMigrator, alreadyDeployed) = _deployOrUseExistingCreate3(context, salt, expected, initCode);

        _verifyDopplerHookMigratorDeployment(dopplerHookMigrator, airlock, poolManager, locker, topUpDistributor);
        _setConfigAddress(context, "doppler_hook_migrator", dopplerHookMigrator);

        if (alreadyDeployed) {
            console.log("DopplerHookMigrator already deployed to:", dopplerHookMigrator);
        } else {
            console.log("DopplerHookMigrator deployed to:", dopplerHookMigrator);
        }
    }

    function _mineDopplerHookMigratorSalt(
        DeployContext memory context,
        address airlock,
        address poolManager,
        address locker,
        address topUpDistributor
    ) internal view returns (bytes32 salt, address expected) {
        bytes32 baseSalt = context.protocolDeployer
            .generateSalt(type(DopplerHookMigrator).name, DOPPLER_HOOK_MIGRATOR_VERSION);

        for (uint88 seed; seed < type(uint88).max; seed++) {
            salt = bytes32(uint256(baseSalt) + seed);
            expected = _computeProtocolCreate3Address(context.protocolDeployer, salt);

            if (
                uint160(expected) & Hooks.ALL_HOOK_MASK == DOPPLER_HOOK_MIGRATOR_FLAGS
                    && (expected.code.length == 0
                        || _isDopplerHookMigratorDeployment(expected, airlock, poolManager, locker, topUpDistributor))
                    && expected != 0x8bBbE586F9A902c15A759FC134A99a2d28bc20c4
                    && expected != 0xF848fEa3329185529B50228BCb36f3B5A60960C4
            ) {
                return (salt, expected);
            }
        }

        revert("DopplerHookMigrator salt not found");
    }

    function _isDopplerHookMigratorDeployment(
        address addr,
        address airlock,
        address poolManager,
        address locker,
        address topUpDistributor
    ) internal view returns (bool) {
        return _staticAddressMatches(addr, abi.encodeWithSelector(bytes4(keccak256("airlock()"))), airlock)
            && _staticAddressMatches(addr, abi.encodeWithSelector(bytes4(keccak256("poolManager()"))), poolManager)
            && _staticAddressMatches(addr, abi.encodeWithSelector(bytes4(keccak256("locker()"))), locker)
            && _staticAddressMatches(
            addr, abi.encodeWithSelector(bytes4(keccak256("TOP_UP_DISTRIBUTOR()"))), topUpDistributor
        );
    }

    function _staticAddressMatches(
        address target,
        bytes memory callData,
        address expected
    ) internal view returns (bool) {
        (bool success, bytes memory result) = target.staticcall(callData);
        return success && result.length == 32 && abi.decode(result, (address)) == expected;
    }

    function _verifyDopplerHookMigratorDeployment(
        address addr,
        address airlock,
        address poolManager,
        address locker,
        address topUpDistributor
    ) internal view {
        DopplerHookMigrator migrator = DopplerHookMigrator(payable(addr));
        require(address(migrator.airlock()) == airlock, "DopplerHookMigrator airlock mismatch");
        require(address(migrator.poolManager()) == poolManager, "DopplerHookMigrator pool manager mismatch");
        require(address(migrator.locker()) == locker, "DopplerHookMigrator locker mismatch");
        require(address(migrator.TOP_UP_DISTRIBUTOR()) == topUpDistributor, "DopplerHookMigrator top-up mismatch");
    }
}

contract DeployDopplerHookMigratorScript is DeployDopplerHookMigrator {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address dopplerHookMigrator) {
        return _deployDopplerHookMigrator(_deployContext());
    }
}

contract DeployDopplerHookMigratorScriptEthereum is DeployDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployDopplerHookMigratorScriptMonad is DeployDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployDopplerHookMigratorScriptBase is DeployDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployDopplerHookMigratorScriptRobinhood is DeployDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployDopplerHookMigratorScriptBaseSepolia is DeployDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
