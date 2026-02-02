// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { LaunchVault } from "src/LaunchVault.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { DERC20 } from "src/tokens/DERC20.sol";

/// @notice Unit tests for LaunchVault using real DERC20 contracts
contract LaunchVaultTest is Test {
    LaunchVault vault;
    Airlock airlock;
    DERC20 asset;
    
    address owner = address(0x1);
    address beneficiary = address(0x3);
    address distributor = address(0x4);
    address trustedExecutor = address(0x5);
    
    uint256 constant INITIAL_SUPPLY = 1000000e18;
    uint256 constant PREBUY_AMOUNT = 10000e18;
    
    function setUp() public {
        vm.startPrank(owner);
        airlock = new Airlock(owner);
        vault = new LaunchVault(address(airlock));
        
        // Set trusted executor
        vault.setTrustedExecutor(trustedExecutor, true);
        vault.setTrustedExecutor(owner, true);
        
        vm.stopPrank();
    }
    
    /// @notice Helper to create a DERC20 token with vault as vesting recipient
    function _createTokenWithVesting() internal returns (DERC20) {
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PREBUY_AMOUNT;
        
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            INITIAL_SUPPLY,
            owner,
            address(airlock),
            0,
            0,
            recipients,
            amounts,
            ""
        );
        
        return token;
    }
    
    function test_depositPrebuy_Success() public {
        DERC20 token = _createTokenWithVesting();
        
        // Release tokens to vault (as vault)
        vm.prank(address(vault));
        token.release();
        
        uint256 amount = token.balanceOf(address(vault));
        assertGt(amount, 0, "Vault should have tokens");
        
        // Record deposit
        vm.prank(trustedExecutor);
        vault.depositPrebuy(address(token), beneficiary, amount);
        
        // Verify
        assertEq(vault.prebuyTotal(address(token)), amount);
        assertEq(token.balanceOf(address(vault)), amount);
    }
    
    function test_depositPrebuy_RevertNotTrustedExecutor() public {
        DERC20 token = _createTokenWithVesting();
        
        address randomUser = address(0x999);
        
        vm.prank(randomUser);
        vm.expectRevert(LaunchVault.NotTrustedExecutor.selector);
        vault.depositPrebuy(address(token), beneficiary, 1000e18);
    }
    
    function test_depositPrebuy_RevertZeroAmount() public {
        DERC20 token = _createTokenWithVesting();
        
        vm.prank(trustedExecutor);
        vm.expectRevert(LaunchVault.ZeroAmount.selector);
        vault.depositPrebuy(address(token), beneficiary, 0);
    }
    
    function test_depositPrebuy_RevertAlreadyDeposited() public {
        DERC20 token = _createTokenWithVesting();
        
        // Release and deposit first time
        vm.prank(address(vault));
        token.release();
        
        uint256 amount = token.balanceOf(address(vault));
        
        vm.prank(trustedExecutor);
        vault.depositPrebuy(address(token), beneficiary, amount);
        
        // Second deposit should fail
        vm.prank(trustedExecutor);
        vm.expectRevert(LaunchVault.AlreadyDeposited.selector);
        vault.depositPrebuy(address(token), beneficiary, amount);
    }
    
    function test_depositPrebuy_RevertInsufficientBalance() public {
        DERC20 token = _createTokenWithVesting();
        
        // Don't release tokens, try to deposit more than vault has (0 balance)
        vm.prank(trustedExecutor);
        vm.expectRevert(abi.encodeWithSelector(LaunchVault.InsufficientBalance.selector, 0, PREBUY_AMOUNT));
        vault.depositPrebuy(address(token), beneficiary, PREBUY_AMOUNT);
    }
    
    function test_setDistributor() public {
        DERC20 token = _createTokenWithVesting();
        
        vm.prank(owner);
        vault.setDistributor(address(token), distributor);
        assertEq(vault.distributor(address(token)), distributor);
    }
    
    function test_releaseToDistributor_Success() public {
        DERC20 token = _createTokenWithVesting();
        
        // Setup
        vm.prank(address(vault));
        token.release();
        
        uint256 amount = token.balanceOf(address(vault));
        
        vm.prank(trustedExecutor);
        vault.depositPrebuy(address(token), beneficiary, amount);
        
        vm.prank(owner);
        vault.setDistributor(address(token), distributor);
        
        // Unlock (as airlock)
        vm.prank(address(airlock));
        token.unlockPool();
        
        // Release
        vault.releaseToDistributor(address(token));
        
        // Verify
        assertEq(vault.prebuyTotal(address(token)), 0);
        assertEq(token.balanceOf(distributor), amount);
        assertEq(token.balanceOf(address(vault)), 0);
    }
    
    function test_releaseToDistributor_RevertNoDistributor() public {
        DERC20 token = _createTokenWithVesting();
        
        vm.prank(address(vault));
        token.release();
        
        uint256 amount = token.balanceOf(address(vault));
        
        vm.prank(trustedExecutor);
        vault.depositPrebuy(address(token), beneficiary, amount);
        
        // Unlock
        vm.prank(address(airlock));
        token.unlockPool();
        
        // Try to release without distributor
        vm.expectRevert(LaunchVault.NoDistributorSet.selector);
        vault.releaseToDistributor(address(token));
    }
    
    function test_releaseToDistributor_RevertNotUnlocked() public {
        DERC20 token = _createTokenWithVesting();
        
        vm.prank(address(vault));
        token.release();
        
        uint256 amount = token.balanceOf(address(vault));
        
        vm.prank(trustedExecutor);
        vault.depositPrebuy(address(token), beneficiary, amount);
        
        vm.prank(owner);
        vault.setDistributor(address(token), distributor);
        
        // Try to release before unlock
        vm.expectRevert(LaunchVault.NotUnlocked.selector);
        vault.releaseToDistributor(address(token));
    }
    
    function test_releaseTo_Success() public {
        DERC20 token = _createTokenWithVesting();
        address recipient = address(0x5);
        
        // Setup
        vm.prank(address(vault));
        token.release();
        
        uint256 amount = token.balanceOf(address(vault));
        
        vm.prank(trustedExecutor);
        vault.depositPrebuy(address(token), beneficiary, amount);
        
        // Unlock
        vm.prank(address(airlock));
        token.unlockPool();
        
        // Release to specific recipient
        vault.releaseTo(address(token), recipient);
        
        // Verify
        assertEq(vault.prebuyTotal(address(token)), 0);
        assertEq(token.balanceOf(recipient), amount);
    }
    
    function test_isUnlocked() public {
        DERC20 token = _createTokenWithVesting();
        
        // Initially locked
        assertFalse(vault.isUnlocked(address(token)));
        
        // Unlock
        vm.prank(address(airlock));
        token.unlockPool();
        
        // Now unlocked
        assertTrue(vault.isUnlocked(address(token)));
    }
    
    function test_setTrustedExecutor() public {
        address newExecutor = address(0x999);
        
        // Initially not trusted
        assertFalse(vault.trustedExecutors(newExecutor));
        
        // Set as trusted
        vm.prank(owner);
        vault.setTrustedExecutor(newExecutor, true);
        assertTrue(vault.trustedExecutors(newExecutor));
        
        // Revoke trust
        vm.prank(owner);
        vault.setTrustedExecutor(newExecutor, false);
        assertFalse(vault.trustedExecutors(newExecutor));
    }
    
    function test_depositPrebuyFromRelease_Success() public {
        DERC20 token = _createTokenWithVesting();
        
        // Call depositPrebuyFromRelease - pulls via DERC20.release()
        vm.prank(trustedExecutor);
        vault.depositPrebuyFromRelease(address(token), beneficiary, PREBUY_AMOUNT);
        
        // Verify
        assertEq(vault.prebuyTotal(address(token)), PREBUY_AMOUNT);
        assertEq(token.balanceOf(address(vault)), PREBUY_AMOUNT);
    }
    
    function test_depositPrebuyFromRelease_RevertWrongAmount() public {
        DERC20 token = _createTokenWithVesting();
        
        // Try with wrong expected amount
        vm.prank(trustedExecutor);
        vm.expectRevert(abi.encodeWithSelector(LaunchVault.WrongAmount.selector, PREBUY_AMOUNT, PREBUY_AMOUNT / 2));
        vault.depositPrebuyFromRelease(address(token), beneficiary, PREBUY_AMOUNT / 2);
    }
}
