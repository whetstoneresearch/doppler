// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Constants } from "@uniswap/v4-core/test/utils/Constants.sol";

import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";
import {
    StreamableFeesLockerV2,
    MigratorApproval,
    NotApprovedMigrator,
    StreamNotFound,
    StreamAlreadyUnlocked,
    Lock
} from "src/StreamableFeesLockerV2.sol";

contract StreamableFeesLockerV2Test is Deployers {
    StreamableFeesLockerV2 public locker;
    address public owner = makeAddr("Owner");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        locker = new StreamableFeesLockerV2(manager, owner);
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

    function test_lock_RevertsWhenSenderNotApprovedMigrator() public {
        (
            PoolKey memory key,
            uint32 lockDuration,
            address recipient,
            BeneficiaryData[] memory beneficiaries,
            Position[] memory positions
        ) = _prepareLockData();

        vm.expectRevert(NotApprovedMigrator.selector);
        locker.lock(key, lockDuration, recipient, beneficiaries, positions);
    }

    function test_lock() public {
        currency0.transfer(address(locker), 100e18);
        currency1.transfer(address(locker), 100e18);

        (
            PoolKey memory key,
            uint32 lockDuration,
            address recipient,
            BeneficiaryData[] memory beneficiaries,
            Position[] memory positions
        ) = _prepareLockData();

        manager.initialize(key, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        locker.approveMigrator(address(this));

        vm.expectEmit();
        emit Lock(key.toId(), beneficiaries, block.timestamp + lockDuration);
        locker.lock(key, lockDuration, recipient, beneficiaries, positions);
    }

    function _prepareLockData()
        internal
        returns (
            PoolKey memory key,
            uint32 lockDuration,
            address recipient,
            BeneficiaryData[] memory beneficiaries,
            Position[] memory positions
        )
    {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        recipient = makeAddr("Recipient");
        lockDuration = 1 days;

        beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        positions = new Position[](2);
        positions[0].salt = bytes32(0);
        positions[0].tickLower = -100_000;
        positions[0].tickUpper = 100_000;
        positions[0].liquidity = 1e18;
        positions[1].salt = bytes32(uint256(1));
        positions[1].tickLower = -50_000;
        positions[1].tickUpper = 50_000;
        positions[1].liquidity = 1e18;
    }
}
