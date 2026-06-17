// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
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
import { Values } from "src/types/Values.sol";

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
        locker.lock(key, lockDuration, recipient, beneficiaries, positions, _defaultValues());
    }

    function test_lock() public {
        (
            PoolKey memory key,
            uint32 lockDuration,
            address recipient,
            BeneficiaryData[] memory beneficiaries,
            Position[] memory positions
        ) = _prepareLockData();
        Values memory values = _defaultValues();

        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        _approveLocker(key, values);

        vm.prank(owner);
        locker.approveMigrator(address(this));

        vm.expectEmit();
        emit Lock(key.toId(), beneficiaries, block.timestamp + lockDuration);
        locker.lock(key, lockDuration, recipient, beneficiaries, positions, values);

        assertEq(key.currency0.balanceOf(address(locker)), 0, "locker should not retain token0 dust");
        assertEq(key.currency1.balanceOf(address(locker)), 0, "locker should not retain token1 dust");
        assertGt(key.currency0.balanceOf(recipient), 0, "recipient should receive token0 dust");
        assertGt(key.currency1.balanceOf(recipient), 0, "recipient should receive token1 dust");
    }

    function test_lock_RefundsNativeDustToRecipient() public {
        (
            PoolKey memory key,
            uint32 lockDuration,
            address recipient,
            BeneficiaryData[] memory beneficiaries,
            Position[] memory positions
        ) = _prepareNativeLockData();
        Values memory values = Values({ value0: 100 ether, value1: 100e18 });

        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        deal(address(this), values.value0);
        _approveLocker(key, values);

        vm.prank(owner);
        locker.approveMigrator(address(this));

        uint256 recipientNativeBefore = recipient.balance;
        uint256 recipientTokenBefore = key.currency1.balanceOf(recipient);

        locker.lock{ value: values.value0 }(key, lockDuration, recipient, beneficiaries, positions, values);

        assertEq(address(locker).balance, 0, "locker should not retain native dust");
        assertEq(key.currency1.balanceOf(address(locker)), 0, "locker should not retain token dust");
        assertGt(recipient.balance, recipientNativeBefore, "recipient should receive native dust");
        assertGt(key.currency1.balanceOf(recipient), recipientTokenBefore, "recipient should receive token dust");
    }

    function test_lock_CannotUsePendingFeesForAnotherLock() public {
        (PoolKey memory keyA,,, BeneficiaryData[] memory beneficiaries, Position[] memory positions) = _lock();
        address beneficiary = beneficiaries[0].beneficiary;
        _swap(keyA, -0.1e18, true);
        _swap(keyA, -0.1e18, false);

        vm.prank(makeAddr("Harvester"));
        (uint128 pendingFees0, uint128 pendingFees1) = locker.collectFees(keyA.toId());
        assertGt(pendingFees0, 0, "token0 fees should be pending");
        assertGt(pendingFees1, 0, "token1 fees should be pending");

        uint256 lockerBalance0Before = keyA.currency0.balanceOf(address(locker));
        uint256 lockerBalance1Before = keyA.currency1.balanceOf(address(locker));

        PoolKey memory keyB = PoolKey({
            currency0: keyA.currency0,
            currency1: keyA.currency1,
            fee: 500,
            tickSpacing: keyA.tickSpacing,
            hooks: keyA.hooks
        });
        manager.initialize(keyB, Constants.SQRT_PRICE_1_1);

        vm.expectRevert();
        locker.lock(
            keyB, 1 days, makeAddr("MaliciousRecipient"), beneficiaries, positions, Values({ value0: 0, value1: 0 })
        );

        assertEq(keyA.currency0.balanceOf(address(locker)), lockerBalance0Before, "pending token0 fees changed");
        assertEq(keyA.currency1.balanceOf(address(locker)), lockerBalance1Before, "pending token1 fees changed");

        uint256 beneficiaryBalance0Before = keyA.currency0.balanceOf(beneficiary);
        uint256 beneficiaryBalance1Before = keyA.currency1.balanceOf(beneficiary);

        vm.prank(beneficiary);
        locker.collectFees(keyA.toId());

        assertEq(
            keyA.currency0.balanceOf(beneficiary),
            beneficiaryBalance0Before + uint256(pendingFees0) * 95 / 100,
            "wrong token0 fee claim"
        );
        assertEq(
            keyA.currency1.balanceOf(beneficiary),
            beneficiaryBalance1Before + uint256(pendingFees1) * 95 / 100,
            "wrong token1 fee claim"
        );
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
        (key, lockDuration, recipient, beneficiaries, positions) = _prepareLockData();
        Values memory values = _defaultValues();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        _approveLocker(key, values);

        vm.prank(owner);
        locker.approveMigrator(address(this));

        locker.lock(key, lockDuration, recipient, beneficiaries, positions, values);
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

    function _prepareNativeLockData()
        internal
        returns (
            PoolKey memory key,
            uint32 lockDuration,
            address recipient,
            BeneficiaryData[] memory beneficiaries,
            Position[] memory positions
        )
    {
        (key, lockDuration, recipient, beneficiaries, positions) = _prepareLockData();
        key.currency0 = Currency.wrap(address(0));
        key.currency1 = currency1;
    }

    function _defaultValues() internal pure returns (Values memory) {
        return Values({ value0: 100e18, value1: 100e18 });
    }

    function _approveLocker(PoolKey memory key, Values memory values) internal {
        if (Currency.unwrap(key.currency0) != address(0)) {
            ERC20(Currency.unwrap(key.currency0)).approve(address(locker), values.value0);
        }

        if (Currency.unwrap(key.currency1) != address(0)) {
            ERC20(Currency.unwrap(key.currency1)).approve(address(locker), values.value1);
        }
    }
}
