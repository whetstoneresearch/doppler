// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

import {
    StreamableFeesLockerV2,
    MigratorApproval,
    NotApprovedMigrator,
    StreamNotFound,
    StreamAlreadyUnlocked
} from "src/StreamableFeesLockerV2.sol";

contract PoolManagerMock is IPoolManager {
    function protocolFeesAccrued(
        Currency currency
    ) external view override returns (uint256 amount) { }

    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external override { }

    function setProtocolFeeController(
        address controller
    ) external override { }

    function collectProtocolFees(
        address recipient,
        Currency currency,
        uint256 amount
    ) external override returns (uint256 amountCollected) { }

    function protocolFeeController() external view override returns (address) { }

    function balanceOf(address owner, uint256 id) external view override returns (uint256 amount) { }

    function allowance(address owner, address spender, uint256 id) external view override returns (uint256 amount) { }

    function isOperator(address owner, address spender) external view override returns (bool approved) { }

    function transfer(address receiver, uint256 id, uint256 amount) external override returns (bool) { }

    function transferFrom(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount
    ) external override returns (bool) { }

    function approve(address spender, uint256 id, uint256 amount) external override returns (bool) { }

    function setOperator(address operator, bool approved) external override returns (bool) { }

    function extsload(
        bytes32 slot
    ) external view override returns (bytes32 value) { }

    function extsload(bytes32 startSlot, uint256 nSlots) external view override returns (bytes32[] memory values) { }

    function extsload(
        bytes32[] calldata slots
    ) external view override returns (bytes32[] memory values) { }

    function exttload(
        bytes32 slot
    ) external view override returns (bytes32 value) { }

    function exttload(
        bytes32[] calldata slots
    ) external view override returns (bytes32[] memory values) { }

    function unlock(
        bytes calldata data
    ) external override returns (bytes memory) { }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external override returns (int24 tick) { }

    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) external override returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) { }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external override returns (BalanceDelta swapDelta) { }

    function donate(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external override returns (BalanceDelta) { }

    function sync(
        Currency currency
    ) external override { }

    function take(Currency currency, address to, uint256 amount) external override { }

    function settle() external payable override returns (uint256 paid) { }

    function settleFor(
        address recipient
    ) external payable override returns (uint256 paid) { }

    function clear(Currency currency, uint256 amount) external override { }

    function mint(address to, uint256 id, uint256 amount) external override { }

    function burn(address from, uint256 id, uint256 amount) external override { }

    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external override { }
}

contract StreamableFeesLockerV2Test is Test {
    IPoolManager public poolManager;
    StreamableFeesLockerV2 public locker;
    address public owner = makeAddr("Owner");

    function setUp() public {
        poolManager = new PoolManagerMock();
        locker = new StreamableFeesLockerV2(poolManager, owner);
    }

    function test_approveMigrator_ApprovesNewMigrator() public {
        address migrator = makeAddr("Migrator");

        vm.prank(owner);
        vm.expectEmit();
        emit MigratorApproval(migrator, true);
        locker.approveMigrator(migrator);

        assertTrue(locker.approvedMigrators(migrator), "Migrator should be approved");
    }

    function test_approveMigrator_RevertsWhenSenderNotOwner() public {
        address migrator = makeAddr("Migrator");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        locker.approveMigrator(migrator);
    }

    function test_revokeMigrator_RevokesMigrator() public {
        address migrator = makeAddr("Migrator");

        vm.prank(owner);
        locker.approveMigrator(migrator);

        vm.prank(owner);
        vm.expectEmit();
        emit MigratorApproval(migrator, false);
        locker.revokeMigrator(migrator);

        assertFalse(locker.approvedMigrators(migrator), "Migrator should be revoked");
    }
}
