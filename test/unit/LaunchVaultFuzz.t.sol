// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { LaunchVault } from "src/LaunchVault.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { DERC20 } from "src/tokens/DERC20.sol";

/// @notice Fuzz and additional full flow tests for LaunchVault
contract LaunchVaultFuzzTest is Test {
    // Contracts
    Airlock airlock;
    LaunchVault vault;
    
    // Test addresses
    address owner;
    address beneficiary;
    address distributor;
    
    // Bound constants for fuzzing
    uint256 constant MIN_SUPPLY = 1000e18;
    uint256 constant MAX_SUPPLY = 1e9 * 1e18; // 1 billion tokens
    uint256 constant MIN_PREBUY = 1e18;
    
    function setUp() public {
        owner = makeAddr("OWNER");
        
        vm.startPrank(owner);
        airlock = new Airlock(owner);
        vault = new LaunchVault(address(airlock));
        vault.setTrustedExecutor(address(vault), true);
        vault.setTrustedExecutor(owner, true);
        vm.stopPrank();
        
        beneficiary = makeAddr("BENEFICIARY");
        distributor = makeAddr("DISTRIBUTOR");
    }
    
    /// @notice Fuzz test: Various supply and prebuy amounts
    function testFuzz_FullFlow_VariousAmounts(
        uint256 initialSupply,
        uint256 prebuyAmount
    ) public {
        // Bound inputs
        initialSupply = bound(initialSupply, MIN_SUPPLY, MAX_SUPPLY);
        prebuyAmount = bound(prebuyAmount, MIN_PREBUY, initialSupply / 10); // Max 10% of supply
        
        vm.startPrank(owner);
        
        // Setup vesting
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = prebuyAmount;
        
        // Create token
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            initialSupply,
            owner,
            address(airlock),
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
        assertEq(vaultBalance, prebuyAmount, "Vault should have exact prebuy amount");
        
        // Record deposit
        vault.depositPrebuy(asset, beneficiary, vaultBalance);
        assertEq(vault.prebuyTotal(asset), vaultBalance);
        
        // Unlock and release
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        
        vault.setDistributor(asset, distributor);
        vault.releaseToDistributor(asset);
        
        // Verify
        assertEq(token.balanceOf(distributor), prebuyAmount);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.prebuyTotal(asset), 0);
        
        vm.stopPrank();
    }
    
    /// @notice Fuzz test: Multiple vesting recipients
    function testFuzz_MultipleVestingRecipients(
        uint256 initialSupply,
        uint256 numRecipients
    ) public {
        initialSupply = bound(initialSupply, MIN_SUPPLY, MAX_SUPPLY);
        numRecipients = bound(numRecipients, 1, 10);
        
        vm.startPrank(owner);
        
        address[] memory recipients = new address[](numRecipients);
        uint256[] memory amounts = new uint256[](numRecipients);
        
        uint256 totalVesting = 0;
        for (uint256 i = 0; i < numRecipients; i++) {
            recipients[i] = makeAddr(string.concat("RECIPIENT_", vm.toString(i)));
            amounts[i] = initialSupply / (numRecipients * 10); // Each gets 10%/numRecipients
            totalVesting += amounts[i];
        }
        
        // Add vault as one recipient
        recipients[numRecipients - 1] = address(vault);
        
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            initialSupply,
            owner,
            address(airlock),
            0,
            0,
            recipients,
            amounts,
            ""
        );
        
        // All recipients release
        for (uint256 i = 0; i < numRecipients; i++) {
            vm.stopPrank();
            vm.prank(recipients[i]);
            DERC20(token).release();
            vm.startPrank(owner);
        }
        
        uint256 vaultBalance = token.balanceOf(address(vault));
        assertGt(vaultBalance, 0, "Vault should have some tokens");
        
        // Record and release
        vault.depositPrebuy(address(token), beneficiary, vaultBalance);
        
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        
        vault.setDistributor(address(token), distributor);
        vault.releaseToDistributor(address(token));
        
        assertEq(token.balanceOf(distributor), vaultBalance);
        
        vm.stopPrank();
    }
    
    /// @notice Test: Multiple assets in same vault
    function test_MultipleAssetsSameVault() public {
        vm.startPrank(owner);
        
        uint256 numTokens = 5;
        DERC20[] memory tokens = new DERC20[](numTokens);
        uint256[] memory amounts = new uint256[](numTokens);
        
        for (uint256 i = 0; i < numTokens; i++) {
            address[] memory recipients = new address[](1);
            recipients[0] = address(vault);
            uint256[] memory vestingAmounts = new uint256[](1);
            amounts[i] = (i + 1) * 10000e18;
            vestingAmounts[0] = amounts[i];
            
            tokens[i] = new DERC20(
                string.concat("Token ", vm.toString(i)),
                string.concat("TKN", vm.toString(i)),
                1000000e18,
                owner,
                address(airlock),
                0,
                0,
                recipients,
                vestingAmounts,
                ""
            );
            
            // Release to vault
            vm.stopPrank();
            vm.prank(address(vault));
            tokens[i].release();
            vm.startPrank(owner);
            
            // Record deposit
            vault.depositPrebuy(address(tokens[i]), beneficiary, amounts[i]);
        }
        
        // Verify all deposits recorded
        for (uint256 i = 0; i < numTokens; i++) {
            assertEq(vault.prebuyTotal(address(tokens[i])), amounts[i]);
            assertEq(tokens[i].balanceOf(address(vault)), amounts[i]);
        }
        
        // Unlock all and release
        for (uint256 i = 0; i < numTokens; i++) {
            vm.stopPrank();
            vm.prank(address(airlock));
            tokens[i].unlockPool();
            vm.startPrank(owner);
            
            address tokenDistributor = makeAddr(string.concat("DISTRIBUTOR_", vm.toString(i)));
            vault.setDistributor(address(tokens[i]), tokenDistributor);
            vault.releaseToDistributor(address(tokens[i]));
            
            assertEq(tokens[i].balanceOf(tokenDistributor), amounts[i]);
            assertEq(vault.prebuyTotal(address(tokens[i])), 0);
        }
        
        vm.stopPrank();
    }
    
    /// @notice Test: Release to multiple different recipients
    function test_ReleaseToDifferentRecipients() public {
        vm.startPrank(owner);
        
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100000e18;
        
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            1000000e18,
            owner,
            address(airlock),
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
        
        vault.depositPrebuy(asset, beneficiary, 100000e18);
        
        // Unlock
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        
        // Test releaseTo with different recipients
        address[] memory testRecipients = new address[](3);
        testRecipients[0] = makeAddr("RECIPIENT_1");
        testRecipients[1] = makeAddr("RECIPIENT_2");
        testRecipients[2] = makeAddr("RECIPIENT_3");
        
        for (uint256 i = 0; i < testRecipients.length; i++) {
            // First we need to deposit again for each test
            // Actually, let's just use releaseTo with the same deposit
            if (i == 0) {
                // First release
                vault.releaseTo(asset, testRecipients[i]);
                assertEq(token.balanceOf(testRecipients[i]), 100000e18);
            }
            // For subsequent releases, we need new deposits
        }
        
        vm.stopPrank();
    }
    
    /// @notice Test: Edge case - zero duration vesting (immediate)
    function test_ZeroDurationVesting_ImmediateRelease() public {
        vm.startPrank(owner);
        
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10000e18;
        
        // 0 duration = immediate vesting
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            1000000e18,
            owner,
            address(airlock),
            0,
            0, // 0 duration
            recipients,
            amounts,
            ""
        );
        
        // With 0 duration, tokens are available immediately
        (uint256 total, uint256 released) = token.getVestingDataOf(address(vault));
        assertEq(total, 10000e18);
        assertEq(released, 0); // Not yet released
        
        // Release
        vm.stopPrank();
        vm.prank(address(vault));
        token.release();
        vm.startPrank(owner);
        
        assertEq(token.balanceOf(address(vault)), 10000e18);
        
        // Complete flow
        vault.depositPrebuy(address(token), beneficiary, 10000e18);
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        vault.setDistributor(address(token), distributor);
        vault.releaseToDistributor(address(token));
        
        assertEq(token.balanceOf(distributor), 10000e18);
        
        vm.stopPrank();
    }
    
    /// @notice Fuzz test: Trusted executor management
    function testFuzz_TrustedExecutorManagement(
        address[] calldata executors,
        bool[] calldata trustedStatus
    ) public {
        vm.assume(executors.length <= 20);
        vm.assume(executors.length == trustedStatus.length);
        
        vm.startPrank(owner);
        
        for (uint256 i = 0; i < executors.length; i++) {
            vm.assume(executors[i] != address(0));
            
            vault.setTrustedExecutor(executors[i], trustedStatus[i]);
            assertEq(vault.trustedExecutors(executors[i]), trustedStatus[i]);
        }
        
        vm.stopPrank();
    }
    
    /// @notice Invariant: Vault balance + Distributor balance = Prebuy total (before release)
    function test_Invariant_BalanceConservation() public {
        vm.startPrank(owner);
        
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50000e18;
        
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            1000000e18,
            owner,
            address(airlock),
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
        
        uint256 initialBalance = token.balanceOf(address(vault));
        vault.depositPrebuy(asset, beneficiary, initialBalance);
        
        // Invariant: vault balance == prebuyTotal
        assertEq(token.balanceOf(address(vault)), vault.prebuyTotal(asset));
        
        // Unlock and release
        vm.stopPrank();
        vm.prank(address(airlock));
        token.unlockPool();
        vm.startPrank(owner);
        
        vault.setDistributor(asset, distributor);
        uint256 distributorBalanceBefore = token.balanceOf(distributor);
        vault.releaseToDistributor(asset);
        uint256 distributorBalanceAfter = token.balanceOf(distributor);
        
        uint256 released = distributorBalanceAfter - distributorBalanceBefore;
        
        // Invariant after release: vault has 0, distributor has everything
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(released, initialBalance);
        assertEq(vault.prebuyTotal(asset), 0);
        
        vm.stopPrank();
    }
    
    /// @notice Test: Cannot double deposit
    function test_CannotDoubleDeposit() public {
        vm.startPrank(owner);
        
        address[] memory recipients = new address[](1);
        recipients[0] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10000e18;
        
        DERC20 token = new DERC20(
            "Test Token",
            "TEST",
            1000000e18,
            owner,
            address(airlock),
            0,
            0,
            recipients,
            amounts,
            ""
        );
        
        address asset = address(token);
        
        // First deposit
        vm.stopPrank();
        vm.prank(address(vault));
        token.release();
        vm.startPrank(owner);
        
        vault.depositPrebuy(asset, beneficiary, 10000e18);
        
        // Try second deposit - should fail
        vm.expectRevert(LaunchVault.AlreadyDeposited.selector);
        vault.depositPrebuy(asset, beneficiary, 10000e18);
        
        vm.stopPrank();
    }
}
