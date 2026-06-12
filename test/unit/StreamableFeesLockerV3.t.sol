// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Constants } from "@uniswap/v4-core/test/utils/Constants.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Deploy } from "@v4-periphery-test/shared/Deploy.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import {
    Lock,
    MigratorApproval,
    NotApprovedMigrator,
    StreamableFeesLockerV3,
    Unlock
} from "src/lockers/StreamableFeesLockerV3.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";

contract StreamableFeesLockerV3Test is Deployers, DeployPermit2 {
    using CurrencyLibrary for Currency;
    using StateLibrary for *;

    StreamableFeesLockerV3 public locker;
    PositionManager public positionManager;
    IAllowanceTransfer public permit2;
    address public owner = makeAddr("Owner");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager = PositionManager(
            payable(address(
                    Deploy.positionManager(
                        address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
                    )
                ))
        );
        locker = new StreamableFeesLockerV3(manager, positionManager, owner);
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

    function test_collectFees_UnlocksAndTransfersPositionsWithoutWithdrawingLiquidity() public {
        (PoolKey memory key, uint32 lockDuration, address recipient,, Position[] memory positions) = _lock();
        uint256[] memory tokenIds = locker.getTokenIds(key.toId());

        uint256 balance0Before = key.currency0.balanceOf(recipient);
        uint256 balance1Before = key.currency1.balanceOf(recipient);

        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(positionManager.ownerOf(tokenIds[i]), address(locker), "locker should hold position before unlock");
            assertEq(
                positionManager.getPositionLiquidity(tokenIds[i]), positions[i].liquidity, "wrong minted liquidity"
            );
        }

        vm.warp(block.timestamp + lockDuration);
        vm.expectEmit();
        emit Unlock(key.toId(), recipient);
        locker.collectFees(key.toId());

        assertEq(key.currency0.balanceOf(recipient), balance0Before, "recipient should not receive token0 on unlock");
        assertEq(key.currency1.balanceOf(recipient), balance1Before, "recipient should not receive token1 on unlock");

        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(positionManager.ownerOf(tokenIds[i]), recipient, "recipient should receive position NFT");
            assertEq(
                positionManager.getPositionLiquidity(tokenIds[i]), positions[i].liquidity, "liquidity should remain"
            );
        }
    }

    function test_collectFees_StreamsFeesBeforeUnlockWithoutTransferringPositions() public {
        (PoolKey memory key,,, BeneficiaryData[] memory beneficiaries, Position[] memory positions) = _lock();
        uint256[] memory tokenIds = locker.getTokenIds(key.toId());
        address beneficiary = beneficiaries[0].beneficiary;
        _swap(key, -0.1e18, true);
        _swap(key, -0.1e18, false);

        uint256 balance0Before = key.currency0.balanceOf(beneficiary);
        uint256 balance1Before = key.currency1.balanceOf(beneficiary);

        vm.prank(beneficiary);
        (uint128 fees0, uint128 fees1) = locker.collectFees(key.toId());

        assertGt(fees0, 0, "token0 fees should be non-zero");
        assertGt(fees1, 0, "token1 fees should be non-zero");
        assertEq(key.currency0.balanceOf(beneficiary), balance0Before + fees0 * 95 / 100, "wrong token0 fees");
        assertEq(key.currency1.balanceOf(beneficiary), balance1Before + fees1 * 95 / 100, "wrong token1 fees");

        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(positionManager.ownerOf(tokenIds[i]), address(locker), "locker should keep locked NFT");
            assertEq(
                positionManager.getPositionLiquidity(tokenIds[i]), positions[i].liquidity, "liquidity should remain"
            );
        }
    }

    function _swap(PoolKey memory key, int128 amountSpecified, bool zeroForOne) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            new bytes(0)
        );
    }

    function _lock()
        internal
        returns (
            PoolKey memory key,
            uint32 lockDuration,
            address recipient,
            BeneficiaryData[] memory beneficiaries,
            Position[] memory positions
        )
    {
        currency0.transfer(address(locker), 100e18);
        currency1.transfer(address(locker), 100e18);

        (key, lockDuration, recipient, beneficiaries, positions) = _prepareLockData();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        locker.approveMigrator(address(this));

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
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 1, hooks: IHooks(address(0))
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
