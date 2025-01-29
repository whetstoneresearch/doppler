// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Factory, IUniswapV2Router02 } from "src/UniswapV2Migrator.sol";
import { Doppler } from "src/Doppler.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { DopplerFixtures, DEFAULT_STARTING_TIME, DEFAULT_START_TICK } from "test/shared/DopplerFixtures.sol";

/// @dev Tests involving migration of liquidity FROM Doppler to ILiquidityMigrator
contract DopplerMigrateTest is DopplerFixtures {
    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_SEPOLIA_RPC_URL"), 9_434_599);
        _deployAirlockAndModules();

        swapRouter = new PoolSwapTest(manager);
    }

    /// @dev Integrators and Protocol can collect fees in native Ether (numeraire)
    function test_v4_fee_collection_native() public {
        address numeraireAddress = Currency.unwrap(CurrencyLibrary.ADDRESS_ZERO);
        (address asset, PoolKey memory poolKey) = _airlockCreateNative();
        IERC20(asset).approve(address(swapRouter), type(uint256).max);

        // Pool created with native Ether
        assertTrue(poolKey.currency0 == CurrencyLibrary.ADDRESS_ZERO);

        // warp to starting time
        vm.warp(block.timestamp + DEFAULT_STARTING_TIME);

        // swap to generate fees in native ether
        Deployers.swap(poolKey, true, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, false, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, true, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, false, -0.1e18, ZERO_BYTES);

        // mock out an early exit to test migration
        Doppler doppler = Doppler(payable(address(poolKey.hooks)));
        _mockEarlyExit(doppler);

        airlock.migrate(asset);

        // protocol collects asset fees
        address recipient = makeAddr("protocolFeeRecipient");
        uint256 protocolFeesAsset = airlock.protocolFees(asset);
        airlock.collectProtocolFees(recipient, asset, protocolFeesAsset);
        assertGt(protocolFeesAsset, 0); // protocolFeesAsset > 0
        assertEq(IERC20(asset).balanceOf(recipient), protocolFeesAsset);

        // protocol collects numeraire fees
        uint256 protocolFeesNumeraire = airlock.protocolFees(numeraireAddress);
        airlock.collectProtocolFees(recipient, numeraireAddress, protocolFeesNumeraire);
        assertGt(protocolFeesNumeraire, 0); // protocolFeesNumeraire > 0
        assertEq(recipient.balance, protocolFeesNumeraire);

        // integrator collects asset fees
        address integratorRecipient = makeAddr("integratorFeeRecipient");
        uint256 integratorFeesAsset = airlock.integratorFees(address(this), asset);
        airlock.collectIntegratorFees(integratorRecipient, asset, integratorFeesAsset);
        assertGt(integratorFeesAsset, 0); // integratorFeesAsset > 0
        assertEq(IERC20(asset).balanceOf(integratorRecipient), integratorFeesAsset);

        // integrator collects numeraire fees
        uint256 integratorFeesNumeraire = airlock.integratorFees(address(this), numeraireAddress);
        airlock.collectIntegratorFees(integratorRecipient, numeraireAddress, integratorFeesNumeraire);
        assertGt(integratorFeesNumeraire, 0); // integratorFeesNumeraire > 0
        assertEq(integratorRecipient.balance, integratorFeesNumeraire);
    }
}
