// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { LaunchVault } from "src/LaunchVault.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { DERC20 } from "src/tokens/DERC20.sol";

/// @notice Simplified E2E test using real DERC20
contract LaunchVaultE2ETest is Test {
    // Contracts
    Airlock airlock;
    LaunchVault vault;
    
    // Test addresses
    address owner = makeAddr("OWNER");
    address beneficiary = makeAddr("BENEFICIARY");
    address distributor = makeAddr("DISTRIBUTOR");
    
    // Test params
    uint256 constant INITIAL_SUPPLY = 1000000e18;
    uint256 constant PREBUY_AMOUNT = 10000e18;
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy Airlock
        airlock = new Airlock(owner);
        
        // Deploy LaunchVault
        vault = new LaunchVault(address(airlock));
        
        // Set executors
        vault.setTrustedExecutor(address(vault), true);
        vault.setTrustedExecutor(owner, true);
        
        vm.stopPrank();
    }
    
    /// @notice Test full flow: Create DERC20 with vesting → Vault receives tokens → Release after unlock
    function test_fullE2EFlow_DERC20Vesting() public {
        vm.startPrank(owner);
        
        // Setup vesting arrays
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault); // Vault is the vesting recipient
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PREBUY_AMOUNT;
        
        // Step 1: Create a real DERC20 token with vault as vesting recipient
        DERC20 token = new DERC20(
            "Test Token",           // name
            "TEST",                 // symbol
            INITIAL_SUPPLY,         // initialSupply
            owner,                  // recipient (gets non-vested portion)
            address(airlock),       // owner (airlock owns the token)
            0,                      // yearlyMintRate (0 = no inflation)
            0,                      // vestingDuration (0 = instant vesting)
            recipients,             // vesting recipients
            amounts,                // vesting amounts
            ""                      // tokenURI
        );
        
        address asset = address(token);
        
        console.log("Token created at:", asset);
        (uint256 vaultVestingTotal, uint256 vaultReleased) = token.getVestingDataOf(address(vault));
        console.log("Vault vesting total:", vaultVestingTotal);
        console.log("Vault released:", vaultReleased);
        
        // Step 2: Release tokens to vault (calling as vault)
        vm.stopPrank();
        vm.prank(address(vault));
        token.release();
        vm.startPrank(owner);
        
        uint256 vaultBalance = token.balanceOf(address(vault));
        console.log("Vault balance after release():", vaultBalance);
        assertEq(vaultBalance, PREBUY_AMOUNT, "Vault should have received vested tokens");
        
        // Step 3: Record the deposit in vault
        vault.depositPrebuy(asset, beneficiary, vaultBalance);
        console.log("Deposit recorded:", vault.prebuyTotal(asset));
        assertEq(vault.prebuyTotal(asset), vaultBalance, "Deposit should be recorded");
        
        // Step 4: Unlock the pool (must be called by airlock as owner)
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        
        bool isUnlocked = vault.isUnlocked(asset);
        console.log("Is pool unlocked:", isUnlocked);
        assertTrue(isUnlocked, "Pool should be unlocked");
        
        // Step 5: Set distributor
        vault.setDistributor(asset, distributor);
        
        // Step 6: Release tokens to distributor
        uint256 distributorBalanceBefore = token.balanceOf(distributor);
        vault.releaseToDistributor(asset);
        uint256 distributorBalanceAfter = token.balanceOf(distributor);
        
        uint256 releasedAmount = distributorBalanceAfter - distributorBalanceBefore;
        console.log("Released amount:", releasedAmount);
        
        // Step 7: Verify final state
        assertEq(releasedAmount, vaultBalance, "All tokens should be released");
        assertEq(token.balanceOf(address(vault)), 0, "Vault should be empty");
        assertEq(vault.prebuyTotal(asset), 0, "Prebuy tracking should be cleared");
        
        vm.stopPrank();
    }
    
    /// @notice Test that tokens can't be released before unlock
    function test_release_RevertBeforeUnlock() public {
        vm.startPrank(owner);
        
        // Setup vesting
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PREBUY_AMOUNT;
        
        // Create token
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            INITIAL_SUPPLY,
            owner,
            address(airlock), // airlock is owner
            0,
            0,
            recipients,
            amounts,
            ""
        );
        
        address asset = address(token);
        
        // Release to vault
        vm.stopPrank();
        vm.prank(address(vault));
        token.release();
        vm.startPrank(owner);
        
        uint256 vaultBalance = token.balanceOf(address(vault));
        
        // Record deposit
        vault.depositPrebuy(asset, beneficiary, vaultBalance);
        vault.setDistributor(asset, distributor);
        
        // Try to release before unlock - should fail
        assertFalse(vault.isUnlocked(asset), "Pool should be locked");
        
        vm.expectRevert(LaunchVault.NotUnlocked.selector);
        vault.releaseToDistributor(asset);
        
        // Now unlock (as airlock) and try again
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        
        assertTrue(vault.isUnlocked(asset), "Pool should be unlocked");
        
        // Should succeed now
        vault.releaseToDistributor(asset);
        assertEq(token.balanceOf(distributor), vaultBalance);
        
        vm.stopPrank();
    }
    
    /// @notice Test the complete bundler callback flow simulation
    function test_bundlerCallbackFlow_Simulation() public {
        vm.startPrank(owner);
        
        // Create token with no vesting to owner
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            INITIAL_SUPPLY,
            owner, // tokens go to owner
            address(airlock), // airlock owns the token
            0,
            0,
            new address[](0), // no vesting
            new uint256[](0),
            ""
        );
        
        address asset = address(token);
        uint256 prebuyAmount = 5000e18;
        
        // Step 1: Owner has tokens (simulating bundler after router)
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY, "Owner should have tokens");
        
        // Step 2: Transfer to vault (simulating callback transfer)
        token.transfer(address(vault), prebuyAmount);
        assertEq(token.balanceOf(address(vault)), prebuyAmount, "Vault should have tokens");
        
        // Step 3: Record deposit (simulating callback call)
        vault.depositPrebuy(asset, beneficiary, prebuyAmount);
        assertEq(vault.prebuyTotal(asset), prebuyAmount, "Should be recorded");
        
        console.log("Bundler callback flow simulated successfully");
        console.log("Tokens in vault:", token.balanceOf(address(vault)));
        console.log("Prebuy recorded:", vault.prebuyTotal(asset));
        
        // Complete the release flow (unlock as airlock)
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        
        vault.setDistributor(asset, distributor);
        vault.releaseToDistributor(asset);
        
        assertEq(token.balanceOf(distributor), prebuyAmount);
        console.log("Tokens released to distributor");
        
        vm.stopPrank();
    }
    
    /// @notice Test depositPrebuyFromRelease with DERC20
    function test_depositPrebuyFromRelease_E2E() public {
        vm.startPrank(owner);
        
        // Setup vesting to vault
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PREBUY_AMOUNT;
        
        // Create token
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            INITIAL_SUPPLY,
            owner,
            address(airlock), // airlock is owner
            0,
            0,
            recipients,
            amounts,
            ""
        );
        
        address asset = address(token);
        
        // Check that vault has vesting allocated
        (uint256 vestingTotal, ) = token.getVestingDataOf(address(vault));
        console.log("Vesting allocated to vault:", vestingTotal);
        assertEq(vestingTotal, PREBUY_AMOUNT);
        
        // Call depositPrebuyFromRelease
        // This will call token.release() which transfers to vault, then records
        vault.depositPrebuyFromRelease(asset, beneficiary, PREBUY_AMOUNT);
        
        // Verify
        assertEq(vault.prebuyTotal(asset), PREBUY_AMOUNT, "Should be recorded");
        assertEq(token.balanceOf(address(vault)), PREBUY_AMOUNT, "Vault should have tokens");
        
        console.log("depositPrebuyFromRelease successful");
        
        // Complete the flow (unlock as airlock)
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        
        vault.setDistributor(asset, distributor);
        vault.releaseToDistributor(asset);
        
        assertEq(token.balanceOf(distributor), PREBUY_AMOUNT);
        console.log("Full flow completed");
        
        vm.stopPrank();
    }
}
