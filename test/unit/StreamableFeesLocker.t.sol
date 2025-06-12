// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { ERC721, ERC721TokenReceiver } from "@solmate/tokens/ERC721.sol";
import {
    StreamableFeesLocker,
    BeneficiaryData,
    PositionData,
    NonPositionManager,
    PositionNotFound,
    PositionAlreadyUnlocked,
    InvalidAddress,
    InvalidShares,
    InvalidTotalShares,
    InvalidLength,
    NotBeneficiary
} from "src/StreamableFeesLocker.sol";

import { console } from "forge-std/console.sol";

contract StreamableFeesLockerTest is Test {
    StreamableFeesLocker public locker;
    IPositionManager public positionManager;

    TestERC20 public token0;
    TestERC20 public token1;

    uint256 constant TOKEN_ID = 1;
    address constant BENEFICIARY_1 = address(0x1111);
    address constant BENEFICIARY_2 = address(0x2222);
    address constant BENEFICIARY_3 = address(0x3333);
    address constant RECIPIENT = address(0x4444);
    uint256 constant WAD = 1e18;
    uint256 constant LOCK_DURATION = 30 days;

    event Lock(uint256 indexed tokenId, BeneficiaryData[] beneficiaries, uint256 unlockDate);
    event Unlock(uint256 indexed tokenId, address recipient);
    event DistributeFees(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event Release(uint256 indexed tokenId, address beneficiary, uint256 amount0, uint256 amount1);
    event UpdateBeneficiary(uint256 indexed tokenId, address oldBeneficiary, address newBeneficiary);

    function setUp() public {
        positionManager = IPositionManager(makeAddr("positionManager"));
        locker = new StreamableFeesLocker(positionManager);

        token0 = new TestERC20(1e27);
        token1 = new TestERC20(1e27);

        // Sort tokens
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
    }

    function test_constructor() public view {
        assertEq(address(locker.positionManager()), address(positionManager));
    }

    function test_onERC721Received_Success() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.7e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.3e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);

        // Mock the call from position manager
        vm.prank(address(positionManager));
        bytes4 selector = locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        assertEq(selector, ERC721TokenReceiver.onERC721Received.selector);

        // Verify position data was stored
        // Note: Weird bug with getter for lockData
    }

    function test_onERC721Received_EmitsEvent() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);

        vm.expectEmit(true, false, false, true);
        emit Lock(TOKEN_ID, beneficiaries, block.timestamp + 30 days);

        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }

    function test_onERC721Received_RevertNotPositionManager() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);

        vm.expectRevert(abi.encodeWithSelector(NonPositionManager.selector));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }

    function test_onERC721Received_RevertNoBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](0);
        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(InvalidLength.selector));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }

    function test_onERC721Received_RevertZeroAddressBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0), shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }

    function test_onERC721Received_RevertZeroShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(InvalidShares.selector));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }

    function test_onERC721Received_RevertIncorrectTotalShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: BENEFICIARY_2,
            shares: 0.4e18 // Total is 0.9e18, not 1e18
         });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(InvalidTotalShares.selector));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }

    function test_distributeFees_SingleBeneficiary_PartialTime() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mock pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Mock getPoolAndPositionInfo
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        // Mock modifyLiquidities
        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Send tokens to locker to simulate fees collected
        token0.transfer(address(locker), 300e18);
        token1.transfer(address(locker), 600e18);

        // Fast forward 10 days (1/3 of lock period)
        vm.warp(block.timestamp + 10 days);

        // Execute distributeFees
        locker.distributeFees(TOKEN_ID);

        // Verify beneficiary claims are updated
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 300e18);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 600e18);
    }

    function test_distributeFees_MultipleBeneficiaries_FullTime() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 0.5e18 // 50%
         });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: BENEFICIARY_2,
            shares: 0.3e18 // 30%
         });
        beneficiaries[2] = BeneficiaryData({
            beneficiary: BENEFICIARY_3,
            shares: 0.2e18 // 20%
         });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mock pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Mock getPoolAndPositionInfo
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        // Mock modifyLiquidities
        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Send tokens to locker to simulate fees collected
        token0.transfer(address(locker), 1000e18);
        token1.transfer(address(locker), 2000e18);

        // Fast forward full lock period
        vm.warp(block.timestamp + LOCK_DURATION);

        // Execute distributeFees
        locker.distributeFees(TOKEN_ID);

        // Verify beneficiaries claims are updated with correct shares
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 500e18); // 50%
        assertEq(locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token0))), 300e18); // 30%
        assertEq(locker.beneficiariesClaims(BENEFICIARY_3, Currency.wrap(address(token0))), 200e18); // 20%

        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 1000e18); // 50%
        assertEq(locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token1))), 600e18); // 30%
        assertEq(locker.beneficiariesClaims(BENEFICIARY_3, Currency.wrap(address(token1))), 400e18); // 20%
    }

    function test_releaseFees_Success() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mock pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Mock getPoolAndPositionInfo
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        // Mock modifyLiquidities
        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Send tokens to locker
        token0.transfer(address(locker), 300e18);
        token1.transfer(address(locker), 600e18);

        // Verify DistributeFees event was emitted
        vm.expectEmit(true, false, false, true);
        emit DistributeFees(TOKEN_ID, 300e18, 600e18);

        // Fast forward and accrue fees
        vm.warp(block.timestamp + 10 days);
        locker.distributeFees(TOKEN_ID);

        // Verify claims are reset
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 300e18);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 600e18);

        // Release fees as beneficiary
        vm.prank(BENEFICIARY_1);
        locker.releaseFees(TOKEN_ID);

        // Verify beneficiary received tokens
        assertEq(token0.balanceOf(BENEFICIARY_1), 300e18);
        assertEq(token1.balanceOf(BENEFICIARY_1), 600e18);

        // Verify claims are reset
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 0);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 0);
    }

    function test_updateBeneficiary_Success() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.6e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.4e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mock pool key for _releaseFees
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Mock getPoolAndPositionInfo
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        // Update beneficiary
        vm.expectEmit(true, false, false, true);
        emit UpdateBeneficiary(TOKEN_ID, BENEFICIARY_1, BENEFICIARY_3);

        vm.prank(BENEFICIARY_1);
        locker.updateBeneficiary(TOKEN_ID, BENEFICIARY_3);

        // Verify beneficiary was updated - note: we can't directly verify this from public getter
        // The update is verified by the event emission
    }

    function test_unlock_Success() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mocks for distributeFees
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Send tokens and fast forward to unlock
        token0.transfer(address(locker), 100e18);
        token1.transfer(address(locker), 200e18);
        vm.warp(block.timestamp + LOCK_DURATION);

        // Accrues fees and unlocks
        vm.expectEmit(true, false, false, true);
        emit Unlock(TOKEN_ID, RECIPIENT);

        locker.distributeFees(TOKEN_ID);
    }

    function test_distributeFees_RevertAlreadyUnlocked() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mocks
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Send tokens and fast forward to unlock
        token0.transfer(address(locker), 100e18);
        token1.transfer(address(locker), 200e18);
        vm.warp(block.timestamp + LOCK_DURATION);
        locker.distributeFees(TOKEN_ID);

        // Try to accrue fees again
        vm.expectRevert(abi.encodeWithSelector(PositionAlreadyUnlocked.selector));
        locker.distributeFees(TOKEN_ID);
    }

    // Fuzz tests
    function testFuzz_onERC721Received_MultipleBeneficiaries(uint8 numBeneficiaries, uint256 seed) public {
        numBeneficiaries = uint8(bound(numBeneficiaries, 1, 10));

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](numBeneficiaries);
        uint256 remainingShares = 1e18;

        for (uint256 i = 0; i < numBeneficiaries - 1; i++) {
            address beneficiary = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            vm.assume(beneficiary != address(0));

            uint256 shares = remainingShares / (numBeneficiaries - i);
            beneficiaries[i] = BeneficiaryData({ beneficiary: beneficiary, shares: uint64(shares) });
            remainingShares -= shares;
        }

        // Last beneficiary gets remaining shares to ensure total equals 1e18
        address lastBeneficiary = address(uint160(uint256(keccak256(abi.encode(seed, numBeneficiaries)))));
        vm.assume(lastBeneficiary != address(0));
        beneficiaries[numBeneficiaries - 1] =
            BeneficiaryData({ beneficiary: lastBeneficiary, shares: uint64(remainingShares) });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);

        vm.prank(address(positionManager));
        bytes4 selector = locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        assertEq(selector, ERC721TokenReceiver.onERC721Received.selector);
    }

    function test_onERC721Received_RevertZeroRecipient() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(address(0), LOCK_DURATION, beneficiaries); // Zero recipient

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }

    function test_releaseFees_NothingToClaim() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mock pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Mock getPoolAndPositionInfo
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        // Try to release without any fees accrued
        vm.prank(BENEFICIARY_1);
        locker.releaseFees(TOKEN_ID);

        // Should succeed but transfer nothing
        assertEq(token0.balanceOf(BENEFICIARY_1), 0);
        assertEq(token1.balanceOf(BENEFICIARY_1), 0);
    }

    function test_updateBeneficiary_RevertNotBeneficiary() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Try to update as non-beneficiary
        vm.prank(BENEFICIARY_2);
        vm.expectRevert(abi.encodeWithSelector(NotBeneficiary.selector));
        locker.updateBeneficiary(TOKEN_ID, BENEFICIARY_3);
    }

    function test_releaseFees_RevertNotBeneficiary() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Try to release as non-beneficiary
        vm.prank(BENEFICIARY_2);
        vm.expectRevert(abi.encodeWithSelector(NotBeneficiary.selector));
        locker.releaseFees(TOKEN_ID);
    }

    function test_updateBeneficiary_RevertZeroAddress() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Try to update to zero address
        vm.prank(BENEFICIARY_1);
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector));
        locker.updateBeneficiary(TOKEN_ID, address(0));
    }

    function test_InvalidTokenId_RevertPositionNotFound() public {
        uint256 invalidTokenId = 999;

        // Test distributeFees with invalid token
        vm.expectRevert(abi.encodeWithSelector(PositionNotFound.selector));
        locker.distributeFees(invalidTokenId);

        // Test releaseFees with invalid token
        vm.expectRevert(abi.encodeWithSelector(PositionNotFound.selector));
        locker.releaseFees(invalidTokenId);

        // Test updateBeneficiary with invalid token
        vm.expectRevert(abi.encodeWithSelector(PositionNotFound.selector));
        locker.updateBeneficiary(invalidTokenId, BENEFICIARY_1);
    }

    // === Timing Tests ===

    function test_distributeFees_exactUnlockTime() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mocks
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Send tokens and fast forward to exact unlock time
        token0.transfer(address(locker), 300e18);
        token1.transfer(address(locker), 600e18);
        vm.warp(block.timestamp + LOCK_DURATION); // Exactly at unlock time

        locker.distributeFees(TOKEN_ID);

        // Should get 100% of fees
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 300e18);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 600e18);
    }

    function test_distributeFees_multipleIntervals() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 1e18 });

        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mocks
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Calculate absolute timestamps
        uint256 startTime = block.timestamp;
        uint256 time25Percent = startTime + 7.5 days; // 25% of 30 days
        uint256 time50Percent = startTime + 15 days; // 50% of 30 days
        uint256 time75Percent = startTime + 22.5 days; // 75% of 30 days
        uint256 time100Percent = startTime + 30 days; // 100% of 30 days

        // Send tokens to locker
        token0.transfer(address(locker), 400e18);
        token1.transfer(address(locker), 800e18);

        // Test at 25% (7.5 days)
        vm.warp(time25Percent);
        locker.distributeFees(TOKEN_ID);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 400e18);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 800e18);

        // Send tokens to locker
        token0.transfer(address(locker), 300e18);
        token1.transfer(address(locker), 500e18);

        // Test at 50% unlock (15 days total)
        vm.warp(time50Percent);
        locker.distributeFees(TOKEN_ID);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 700e18);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 1300e18);

        // Send tokens to locker
        token0.transfer(address(locker), 100e18);
        token1.transfer(address(locker), 200e18);

        // Test at 75% unlock (22.5 days total)
        vm.warp(time75Percent);
        locker.distributeFees(TOKEN_ID);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 800e18);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 1500e18);

        // Send tokens to locker
        token0.transfer(address(locker), 600e18);
        token1.transfer(address(locker), 200e18);

        // Test at 100% unlock (30 days total)
        vm.warp(time100Percent);
        locker.distributeFees(TOKEN_ID);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 1400e18);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 1700e18);

        // Fee distribution should revert now that it is unlocked
        vm.expectRevert(abi.encodeWithSelector(PositionAlreadyUnlocked.selector));
        locker.distributeFees(TOKEN_ID);
    }

    // === Property-Based Tests ===

    function testFuzz_feesAlwaysFullyDistributed(uint256 amount0, uint256 amount1, uint256 timeElapsed) public {
        // Bound inputs
        amount0 = bound(amount0, 0, 1e24); // Max 1M tokens
        amount1 = bound(amount1, 0, 1e24);
        timeElapsed = bound(timeElapsed, 0, LOCK_DURATION);

        // Setup 3 beneficiaries with different shares
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 0.5e18 // 50%
         });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: BENEFICIARY_2,
            shares: 0.3e18 // 30%
         });
        beneficiaries[2] = BeneficiaryData({
            beneficiary: BENEFICIARY_3,
            shares: 0.2e18 // 20%
         });

        // Lock position
        bytes memory positionData = abi.encode(RECIPIENT, LOCK_DURATION, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);

        // Setup mocks
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Send fees to locker
        if (amount0 > 0) token0.transfer(address(locker), amount0);
        if (amount1 > 0) token1.transfer(address(locker), amount1);

        // Advance time
        vm.warp(block.timestamp + timeElapsed);

        // Accrue fees
        locker.distributeFees(TOKEN_ID);

        // Calculate expected distributions based on time
        uint256 expectedDistribution0 = amount0;
        uint256 expectedDistribution1 = amount1;

        // Sum all claims
        uint256 totalClaims0 = locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0)))
            + locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token0)))
            + locker.beneficiariesClaims(BENEFICIARY_3, Currency.wrap(address(token0)));

        uint256 totalClaims1 = locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1)))
            + locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token1)))
            + locker.beneficiariesClaims(BENEFICIARY_3, Currency.wrap(address(token1)));

        // Property: Total claims should equal expected distribution (within rounding error of 3 wei)
        assertEq(totalClaims0, expectedDistribution0, "Total token0 claims should equal distributed amount");
        assertEq(totalClaims1, expectedDistribution1, "Total token1 claims should equal distributed amount");
        uint256 roundingError = beneficiaries.length - 1;

        // Property: Individual claims should match their share percentages
        if (expectedDistribution0 > 0) {
            assertApproxEqAbs(
                locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))),
                (expectedDistribution0 * 50) / 100,
                roundingError,
                "Beneficiary 1 should get 50% of token0"
            );
            assertApproxEqAbs(
                locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token0))),
                (expectedDistribution0 * 30) / 100,
                roundingError,
                "Beneficiary 2 should get 30% of token0"
            );
            assertApproxEqAbs(
                locker.beneficiariesClaims(BENEFICIARY_3, Currency.wrap(address(token0))),
                (expectedDistribution0 * 20) / 100,
                roundingError,
                "Beneficiary 3 should get 20% of token0"
            );
        }
    }

    function test_NoOpGovernance_PermanentLock() public {
        // Create beneficiaries for a no-op governance position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 0.6e18 // 60%
         });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: BENEFICIARY_2,
            shares: 0.4e18 // 40%
         });

        // Use DEAD_ADDRESS as recipient for no-op governance
        address DEAD_ADDRESS = address(0xdead);
        bytes memory positionData = abi.encode(DEAD_ADDRESS, LOCK_DURATION, beneficiaries);

        // Lock the position
        vm.prank(address(positionManager));
        locker.onERC721Received(address(0), address(0), TOKEN_ID, positionData);

        // Setup mocks
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, TOKEN_ID),
            abi.encode(poolKey, 0)
        );

        vm.mockCall(
            address(positionManager), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), abi.encode()
        );

        // Send tokens to locker to simulate fees
        token0.transfer(address(locker), 1000e18);
        token1.transfer(address(locker), 2000e18);

        // Fast forward past lock duration
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        // Distribute fees - should NOT transfer the NFT because recipient is DEAD_ADDRESS
        locker.distributeFees(TOKEN_ID);

        // Verify the position is marked as locked and NFT not transferred
        (address recipient, uint32 startDate, uint32 lockDuration, bool isUnlocked) = locker.positions(TOKEN_ID);
        assertGt(startDate, 0, "Start date should be greater than 0");
        assertFalse(isUnlocked, "Position should remain locked after we pass lock duration");
        assertEq(recipient, DEAD_ADDRESS, "Recipient should still be DEAD_ADDRESS");

        // Verify beneficiaries received their shares
        uint256 expectedClaim0_B1 = 600e18; // 60% of 1000e18
        uint256 expectedClaim1_B1 = 1200e18; // 60% of 2000e18
        uint256 expectedClaim0_B2 = 400e18; // 40% of 1000e18
        uint256 expectedClaim1_B2 = 800e18; // 40% of 2000e18

        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), expectedClaim0_B1);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), expectedClaim1_B1);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token0))), expectedClaim0_B2);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token1))), expectedClaim1_B2);

        // Beneficiaries should still be able to collect more fees in the future
        // Send more tokens and distribute again
        token0.transfer(address(locker), 500e18);
        token1.transfer(address(locker), 300e18);

        // Fast forward past lock duration
        vm.warp(block.timestamp + (LOCK_DURATION * 2));

        // Try to distribute fees again which should succeed because the NFT is permanently locked.
        locker.distributeFees(TOKEN_ID);

        // Verify the position is marked as locked and NFT not transferred
        (recipient, startDate, lockDuration, isUnlocked) = locker.positions(TOKEN_ID);
        assertGt(startDate, 0, "Start date should be greater than 0");
        assertFalse(isUnlocked, "Position should remain locked after we pass lock duration");
        assertEq(recipient, DEAD_ADDRESS, "Recipient should still be DEAD_ADDRESS");

        // Verify beneficiaries received their shares
        expectedClaim0_B1 = 900e18; // 60% of 1000e18
        expectedClaim1_B1 = 1380e18; // 60% of 2000e18
        expectedClaim0_B2 = 600e18; // 40% of 1000e18
        expectedClaim1_B2 = 920e18; // 40% of 2000e18

        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), expectedClaim0_B1);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), expectedClaim1_B1);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token0))), expectedClaim0_B2);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token1))), expectedClaim1_B2);
    }
}
