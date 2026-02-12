pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { TwapSellExecutorHook, ITwapVault, InvalidTwapSchedule } from "src/dopplerHooks/TwapSellExecutorHook.sol";
import { TwapVault } from "src/twap/TwapVault.sol";

using PoolIdLibrary for PoolKey;

contract TwapSellExecutorHookUnitTest is Test {
    address initializer = makeAddr("initializer");
    address airlockOwner = makeAddr("airlockOwner");
    address buybackDst = makeAddr("buybackDst");

    TestERC20 numeraire;
    TestERC20 asset;

    TwapVault vault;
    TwapSellExecutorHook hook;

    function setUp() public {
        numeraire = new TestERC20(1e48);
        asset = new TestERC20(1e48);

        vault = new TwapVault(airlockOwner);
        hook = new TwapSellExecutorHook(initializer, IPoolManager(address(0x1111)), ITwapVault(address(vault)));

        vm.prank(airlockOwner);
        vault.setExecutor(address(hook));
    }

    function test_onInitialization_StoresScheduleAndRegistersPool() public {
        PoolKey memory key = _poolKey();
        PoolId poolId = key.toId();

        uint32 startTs = uint32(block.timestamp);
        uint32 endTs = startTs + 1 days;

        bytes memory data = abi.encode(
            address(numeraire),
            buybackDst,
            startTs,
            endTs,
            uint256(123),
            uint256(456),
            uint256(789)
        );

        vm.prank(initializer);
        hook.onInitialization(address(asset), key, data);

        (uint32 storedStart, uint32 storedEnd, uint256 rate, uint256 maxPerExec, uint256 maxAcc) = hook.getTwapSellSchedule(poolId);
        assertEq(storedStart, startTs);
        assertEq(storedEnd, endTs);
        assertEq(rate, 123);
        assertEq(maxPerExec, 456);
        assertEq(maxAcc, 789);

        (address storedAsset, address storedNum, address storedDst) = vault.poolInfo(poolId);
        assertEq(storedAsset, address(asset));
        assertEq(storedNum, address(numeraire));
        assertEq(storedDst, buybackDst);
    }

    function test_onInitialization_RevertsOnInvalidSchedule() public {
        PoolKey memory key = _poolKey();
        uint32 startTs = uint32(block.timestamp);
        uint32 endTs = startTs;

        bytes memory data = abi.encode(address(numeraire), buybackDst, startTs, endTs, uint256(1), uint256(0), uint256(0));

        vm.prank(initializer);
        vm.expectRevert(InvalidTwapSchedule.selector);
        hook.onInitialization(address(asset), key, data);
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        Currency currency0 = Currency.wrap(address(numeraire));
        Currency currency1 = Currency.wrap(address(asset));
        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);
        key = PoolKey({ currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(initializer) });
    }
}
