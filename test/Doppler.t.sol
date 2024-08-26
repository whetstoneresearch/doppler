pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";

import {DopplerImplementation} from "./DopplerImplementation.sol";

contract DopplerTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MIN_TICK_SPACING = 1;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    DopplerImplementation doppler0 = DopplerImplementation(
        address(uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG
        ))
    );
    PoolKey key0;
    PoolId id0;

    DopplerImplementation[] dopplers;
    PoolKey[] keys;
    PoolId[] ids;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        manager = new PoolManager(500000);

        vm.record();
        DopplerImplementation impl0 =
            new DopplerImplementation(
                manager, 
                // TODO: Add params here
                doppler0
            );
        (, bytes32[] memory writes) = vm.accesses(address(impl0));
        vm.etch(address(doppler0), address(impl0).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(doppler0), slot, vm.load(address(impl0), slot));
            }
        }
        key0 = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            0,
            MIN_TICK_SPACING,
            IHooks(address(impl0))
        );
        id0 = key.toId();

        // TODO: Add more variations of doppler implementations

        dopplers.push(doppler0);
        keys.push(key0);
        ids.push(id0);
    }
}