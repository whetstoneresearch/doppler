// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IExtsload } from "@v4-core/interfaces/IExtsload.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";

contract UniswapV4MigratorTest is Test {
    using PoolIdLibrary for PoolKey;

    address public airlock = makeAddr("airlock");
    address public poolManager = makeAddr("poolManager");
    address public positionManager = makeAddr("positionManager");

    UniswapV4Migrator public migrator;
    TestERC20 public asset;
    TestERC20 public numeraire;

    function setUp() public {
        asset = new TestERC20(1e27);
        numeraire = new TestERC20(1e27);
        migrator = new UniswapV4Migrator(airlock, poolManager, payable(positionManager));
    }

    /// @dev We're defining `extsload` here again (from `IExtslod`) because solc is not able to
    /// determine the right function selector to use when importing the interface
    function extsload(
        bytes32 slot
    ) external view returns (bytes32 value) { }

    function test_initialize_StoresPoolKey() public {
        int24 tickSpacing = 8;
        uint24 fee = 3000;

        address token0 = address(asset);
        address token1 = address(numeraire);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        migrator.initialize(address(asset), address(numeraire), abi.encode(fee, tickSpacing));

        (Currency currency0_, Currency currency1_, uint24 fee_, int24 tickSpacing_, IHooks hooks_) =
            migrator.getPoolKeyForPair(token0, token1);
        assertEq(Currency.unwrap(currency0_), token0);
        assertEq(Currency.unwrap(currency1_), token1);
        assertEq(fee_, fee);
        assertEq(tickSpacing_, tickSpacing);
        assertEq(address(hooks_), address(0));
    }

    function test_migrate_MigratesToUniV4() public {
        int24 tickSpacing = 8;
        uint24 fee = 3000;

        address token0 = address(asset);
        address token1 = address(numeraire);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        migrator.initialize(address(asset), address(numeraire), abi.encode(fee, tickSpacing));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            hooks: IHooks(address(0)),
            fee: fee,
            tickSpacing: tickSpacing
        });

        bytes memory getSlot0Call = abi.encodeWithSelector(this.extsload.selector, poolKey.toId());
        vm.mockCall(poolManager, getSlot0Call, abi.encode(uint160(0), int24(0), uint24(0), uint24(0)));
        vm.expectCall(poolManager, getSlot0Call);

        bytes memory initializeCall =
            abi.encodeWithSelector(IPoolManager.initialize.selector, poolKey, TickMath.MIN_SQRT_PRICE);
        vm.expectCall(poolManager, initializeCall);

        // TODO: Encoding the call here is pretty tedious since we have to use the PositionManager
        vm.mockCall(poolManager, initializeCall, new bytes(0));
    }
}
