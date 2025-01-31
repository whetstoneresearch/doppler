// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { MAX_TICK_SPACING } from "src/Doppler.sol";
import { DopplerTickLibrary } from "../util/DopplerTickLibrary.sol";
import { DopplerFixtures, DEFAULT_START_TICK } from "test/shared/DopplerFixtures.sol";

contract UniswapV4InitializerTest is DopplerFixtures {
    using StateLibrary for IPoolManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_SEPOLIA_RPC_URL"), 9_434_599);
        _deployAirlockAndModules();
    }

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(airlock), "Wrong airlock");
    }

    function test_fuzz_v4_initialize_fee_tickSpacing(uint24 fee, int24 tickSpacing) public {
        fee = uint24(bound(fee, 0, 1_000_000)); // 0.00% to 100%
        tickSpacing = int24(bound(tickSpacing, 1, MAX_TICK_SPACING));

        // initialize an auction on Doppler
        address numeraire = Currency.unwrap(CurrencyLibrary.ADDRESS_ZERO);
        bool isAssetToken0 = false;
        (address asset, PoolKey memory poolKey) = _airlockCreate(numeraire, isAssetToken0, fee, tickSpacing);

        assertTrue(poolKey.currency0 == CurrencyLibrary.ADDRESS_ZERO);
        assertTrue(poolKey.currency1 == Currency.wrap(asset));

        assertEq(poolKey.fee, fee);
        assertEq(poolKey.tickSpacing, tickSpacing);

        // pool is initialized
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        int24 startTick =
            DopplerTickLibrary.alignComputedTickWithTickSpacing(isAssetToken0, DEFAULT_START_TICK, tickSpacing);
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(startTick), "Wrong starting price");
    }
}
