// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Vm } from "forge-std/Vm.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { BeneficiaryData, StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { UniswapV4Migrator } from "src/migrators/UniswapV4Migrator.sol";
import { UniswapV4MigratorHook } from "src/migrators/UniswapV4MigratorHook.sol";

function deployUniswapV4Migrator(
    Vm vm,
    function(string memory, bytes memory, address) deployCodeTo,
    Airlock airlock,
    address airlockOwner,
    address poolManager,
    address positionManager
) returns (StreamableFeesLocker locker, UniswapV4MigratorHook migratorHook, UniswapV4Migrator migrator) {
    locker = new StreamableFeesLocker(IPositionManager(positionManager), airlockOwner);
    migratorHook = UniswapV4MigratorHook(
        address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
            ^ (0x4444 << 144)
        )
    );
    migrator = new UniswapV4Migrator(
        address(airlock),
        IPoolManager(poolManager),
        PositionManager(payable(positionManager)),
        locker,
        IHooks(migratorHook)
    );
    deployCodeTo("UniswapV4MigratorHook", abi.encode(address(poolManager), address(migrator)), address(migratorHook));

    address[] memory modules = new address[](1);
    modules[0] = address(migrator);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.LiquidityMigrator;
    vm.startPrank(airlockOwner);
    airlock.setModuleState(modules, states);
    locker.approveMigrator(address(migrator));
    vm.stopPrank();
}

function prepareUniswapV4MigratorData(Airlock airlock) view returns (bytes memory) {
    BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
    beneficiaries[0] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });
    beneficiaries[1] = BeneficiaryData({ beneficiary: address(0xbeef), shares: 0.05e18 });
    beneficiaries[2] = BeneficiaryData({ beneficiary: address(0xb0b), shares: 0.9e18 });
    beneficiaries = sortBeneficiaries(beneficiaries);

    int24 tickSpacing = 8;

    return abi.encode(2000, tickSpacing, 30 days, beneficiaries);
}

function sortBeneficiaries(BeneficiaryData[] memory beneficiaries) pure returns (BeneficiaryData[] memory) {
    uint256 length = beneficiaries.length;
    for (uint256 i = 0; i < length - 1; i++) {
        for (uint256 j = 0; j < length - i - 1; j++) {
            if (uint160(beneficiaries[j].beneficiary) > uint160(beneficiaries[j + 1].beneficiary)) {
                BeneficiaryData memory temp = beneficiaries[j];
                beneficiaries[j] = beneficiaries[j + 1];
                beneficiaries[j + 1] = temp;
            }
        }
    }
    return beneficiaries;
}
