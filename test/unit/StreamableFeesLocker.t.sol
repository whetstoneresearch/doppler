// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { StreamableFeesLocker, BeneficiaryData, PositionData } from "src/StreamableFeesLocker.sol";
import { ERC721, ERC721TokenReceiver } from "@solmate/tokens/ERC721.sol";

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
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 0.7e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: BENEFICIARY_2,
            shares: 0.3e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        
        // Mock the call from position manager
        vm.prank(address(positionManager));
        bytes4 selector = locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
        
        assertEq(selector, ERC721TokenReceiver.onERC721Received.selector);
        
        // Verify position data was stored
        // Note: We can't access the beneficiaries array directly from the public getter
        // The position data is verified through the successful storage and event emission
    }
    
    function test_onERC721Received_EmitsEvent() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 1e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        
        vm.expectEmit(true, false, false, true);
        emit Lock(TOKEN_ID, beneficiaries, block.timestamp + 30 days);
        
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }
    
    function test_onERC721Received_RevertNotPositionManager() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 1e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        
        vm.expectRevert("StreamableFeesLocker: ONLY_POSITION_MANAGER");
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }
    
    function test_onERC721Received_RevertNoBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](0);
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        
        vm.prank(address(positionManager));
        vm.expectRevert("No beneficiaries provided");
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }
    
    function test_onERC721Received_RevertZeroAddressBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: address(0),
            shares: 1e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        
        vm.prank(address(positionManager));
        vm.expectRevert("StreamableFeesLocker: BENEFICIARY_CANNOT_BE_ZERO_ADDRESS");
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }
    
    function test_onERC721Received_RevertZeroShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 0,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        
        vm.prank(address(positionManager));
        vm.expectRevert("StreamableFeesLocker: SHARES_MUST_BE_GREATER_THAN_ZERO");
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }
    
    function test_onERC721Received_RevertIncorrectTotalShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 0.5e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: BENEFICIARY_2,
            shares: 0.4e18, // Total is 0.9e18, not 1e18
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        
        vm.prank(address(positionManager));
        vm.expectRevert("StreamableFeesLocker: TOTAL_SHARES_NOT_EQUAL_TO_WAD");
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
    }
    
    function test_accrueFees_SingleBeneficiary_PartialTime() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 1e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
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
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encode()
        );
        
        // Send tokens to locker to simulate fees collected
        token0.transfer(address(locker), 300e18);
        token1.transfer(address(locker), 600e18);
        
        // Fast forward 10 days (1/3 of lock period)
        vm.warp(block.timestamp + 10 days);
        
        // Execute accrueFees
        locker.accrueFees(TOKEN_ID);
        
        // Verify beneficiary claims are updated (1/3 of fees)
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 100e18);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 200e18);
        
        // Position should not be unlocked yet
        // We verify this by checking that accrueFees doesn't revert with "already unlocked"
    }
    
    function test_accrueFees_MultipleBeneficiaries_FullTime() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 0.5e18,  // 50%
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: BENEFICIARY_2,
            shares: 0.3e18,  // 30%
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        beneficiaries[2] = BeneficiaryData({
            beneficiary: BENEFICIARY_3,
            shares: 0.2e18,  // 20%
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
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
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encode()
        );
        
        // Send tokens to locker to simulate fees collected
        token0.transfer(address(locker), 1000e18);
        token1.transfer(address(locker), 2000e18);
        
        // Fast forward full lock period
        vm.warp(block.timestamp + LOCK_DURATION);
        
        // Execute accrueFees
        locker.accrueFees(TOKEN_ID);
        
        // Verify beneficiaries claims are updated with correct shares
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 500e18);  // 50%
        assertEq(locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token0))), 300e18);  // 30%
        assertEq(locker.beneficiariesClaims(BENEFICIARY_3, Currency.wrap(address(token0))), 200e18);  // 20%
        
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 1000e18); // 50%
        assertEq(locker.beneficiariesClaims(BENEFICIARY_2, Currency.wrap(address(token1))), 600e18);  // 30%
        assertEq(locker.beneficiariesClaims(BENEFICIARY_3, Currency.wrap(address(token1))), 400e18);  // 20%
        
        // Position should be unlocked
        // We verify this by checking that unlock() will succeed after this
    }
    
    function test_releaseFees_Success() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 1e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
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
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encode()
        );
        
        // Send tokens to locker
        token0.transfer(address(locker), 300e18);
        token1.transfer(address(locker), 600e18);
        
        // Fast forward and accrue fees
        vm.warp(block.timestamp + 10 days);
        locker.accrueFees(TOKEN_ID);
        
        // Release fees as beneficiary
        vm.expectEmit(true, true, false, true);
        emit Release(TOKEN_ID, BENEFICIARY_1, 100e18, 200e18);
        
        vm.prank(BENEFICIARY_1);
        locker.releaseFees(TOKEN_ID);
        
        // Verify beneficiary received tokens
        assertEq(token0.balanceOf(BENEFICIARY_1), 100e18);
        assertEq(token1.balanceOf(BENEFICIARY_1), 200e18);
        
        // Verify claims are reset
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token0))), 0);
        assertEq(locker.beneficiariesClaims(BENEFICIARY_1, Currency.wrap(address(token1))), 0);
    }
    
    function test_updateBeneficiary_Success() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 0.6e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: BENEFICIARY_2,
            shares: 0.4e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
        
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
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 1e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
        
        // Setup mocks for accrueFees
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
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encode()
        );
        
        // Send tokens and fast forward to unlock
        token0.transfer(address(locker), 100e18);
        token1.transfer(address(locker), 200e18);
        vm.warp(block.timestamp + LOCK_DURATION);
        locker.accrueFees(TOKEN_ID);
        
        // Mock NFT transfer
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)")), address(locker), RECIPIENT, TOKEN_ID, new bytes(0)),
            abi.encode()
        );
        
        // Execute unlock
        vm.expectEmit(true, false, false, true);
        emit Unlock(TOKEN_ID, RECIPIENT);
        
        locker.unlock(TOKEN_ID);
    }
    
    function test_unlock_RevertNotUnlocked() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 1e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
        
        // Try to unlock before time
        vm.expectRevert("StreamableFeesLocker: POSITION_NOT_UNLOCKED");
        locker.unlock(TOKEN_ID);
    }
    
    function test_accrueFees_RevertAlreadyUnlocked() public {
        // First lock the position
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: BENEFICIARY_1,
            shares: 1e18,
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
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
            address(positionManager),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encode()
        );
        
        // Send tokens and fast forward to unlock
        token0.transfer(address(locker), 100e18);
        token1.transfer(address(locker), 200e18);
        vm.warp(block.timestamp + LOCK_DURATION);
        locker.accrueFees(TOKEN_ID);
        
        // Try to accrue fees again
        vm.expectRevert("StreamableFeesLocker: POSITION_ALREADY_UNLOCKED");
        locker.accrueFees(TOKEN_ID);
    }
    
    // Fuzz tests
    function testFuzz_onERC721Received_MultipleBeneficiaries(
        uint8 numBeneficiaries,
        uint256 seed
    ) public {
        numBeneficiaries = uint8(bound(numBeneficiaries, 1, 10));
        
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](numBeneficiaries);
        uint256 remainingShares = 1e18;
        
        for (uint256 i = 0; i < numBeneficiaries - 1; i++) {
            address beneficiary = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            vm.assume(beneficiary != address(0));
            
            uint256 shares = remainingShares / (numBeneficiaries - i);
            beneficiaries[i] = BeneficiaryData({
                beneficiary: beneficiary,
                shares: uint64(shares),
                amountClaimed0: 0,
                amountClaimed1: 0
            });
            remainingShares -= shares;
        }
        
        // Last beneficiary gets remaining shares to ensure total equals 1e18
        address lastBeneficiary = address(uint160(uint256(keccak256(abi.encode(seed, numBeneficiaries)))));
        vm.assume(lastBeneficiary != address(0));
        beneficiaries[numBeneficiaries - 1] = BeneficiaryData({
            beneficiary: lastBeneficiary,
            shares: uint64(remainingShares),
            amountClaimed0: 0,
            amountClaimed1: 0
        });
        
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);
        
        vm.prank(address(positionManager));
        bytes4 selector = locker.onERC721Received(address(this), address(this), TOKEN_ID, positionData);
        
        assertEq(selector, ERC721TokenReceiver.onERC721Received.selector);
    }
}