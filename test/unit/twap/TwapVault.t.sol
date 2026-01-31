pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";

import {
    TwapVault,
    PoolRegistrationMismatch,
    SenderNotAuthorized,
    InsufficientInventory,
    SenderNotExecutor
} from "src/twap/TwapVault.sol";

contract TwapVaultUnitTest is Test {
    TwapVault vault;
    TestERC20 token;

    address owner = makeAddr("owner");
    address executor = makeAddr("executor");
    address buybackDst = makeAddr("buybackDst");
    address other = makeAddr("other");

    PoolId poolId = PoolId.wrap(bytes32(uint256(1)));

    function setUp() public {
        vault = new TwapVault(owner);
        token = new TestERC20(1e48);

        vm.prank(owner);
        vault.setExecutor(executor);

        vm.prank(executor);
        vault.registerPool(poolId, address(token), address(0xBEEF), buybackDst);

        token.transfer(buybackDst, 1e24);
    }

    function test_registerPool_Idempotent() public {
        vm.prank(executor);
        vault.registerPool(poolId, address(token), address(0xBEEF), buybackDst);
    }

    function test_registerPool_RevertsOnMismatch() public {
        vm.prank(executor);
        vm.expectRevert(PoolRegistrationMismatch.selector);
        vault.registerPool(poolId, address(token), address(0xCAFE), buybackDst);
    }

    function test_deposit_IncrementsInventory() public {
        uint256 amount = 123e18;

        vm.startPrank(buybackDst);
        token.approve(address(vault), amount);
        vault.deposit(poolId, address(token), amount);
        vm.stopPrank();

        assertEq(vault.inventory(poolId, address(token)), amount);
        assertEq(token.balanceOf(address(vault)), amount);
    }

    function test_deposit_RevertsWhenNotBuybackDst() public {
        uint256 amount = 1e18;

        vm.startPrank(other);
        token.approve(address(vault), amount);
        vm.expectRevert(SenderNotAuthorized.selector);
        vault.deposit(poolId, address(token), amount);
        vm.stopPrank();
    }

    function test_withdraw_DecrementsInventory() public {
        uint256 amount = 10e18;

        vm.startPrank(buybackDst);
        token.approve(address(vault), amount);
        vault.deposit(poolId, address(token), amount);

        vault.withdraw(poolId, address(token), 4e18, other);
        vm.stopPrank();

        assertEq(vault.inventory(poolId, address(token)), 6e18);
        assertEq(token.balanceOf(other), 4e18);
    }

    function test_withdraw_RevertsWhenInsufficientInventory() public {
        vm.prank(buybackDst);
        vm.expectRevert(InsufficientInventory.selector);
        vault.withdraw(poolId, address(token), 1, other);
    }

    function test_debitToExecutor_OnlyExecutor() public {
        vm.prank(other);
        vm.expectRevert(SenderNotExecutor.selector);
        vault.debitToExecutor(poolId, address(token), 1, other);
    }
}
