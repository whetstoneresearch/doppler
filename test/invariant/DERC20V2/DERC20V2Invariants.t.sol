// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DERC20V2, VestingData, VestingSchedule } from "src/tokens/DERC20V2.sol";
import { DERC20V2Handler } from "test/invariant/DERC20V2/DERC20V2Handler.sol";

/**
 * @title DERC20V2InvariantsTest
 * @notice Invariant tests for DERC20V2 multi-schedule vesting
 * @dev Tests critical properties that must always hold regardless of action sequence
 */
contract DERC20V2InvariantsTest is Test {
    DERC20V2 public token;
    DERC20V2Handler public handler;

    // Test parameters
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 constant YEARLY_MINT_RATE = 0.02 ether; // 2%

    // Beneficiaries
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public owner = makeAddr("owner");
    address public recipient = makeAddr("recipient");

    address[] public beneficiaries;
    VestingSchedule[] public schedules;
    uint256[] public scheduleIds;
    uint256[] public amounts;

    function setUp() public {
        // Create diverse vesting schedules
        schedules.push(VestingSchedule({ cliff: 30 days, duration: 365 days })); // Standard 1-year vest, 30-day cliff
        schedules.push(VestingSchedule({ cliff: 0, duration: 180 days })); // No cliff, 6-month vest
        schedules.push(VestingSchedule({ cliff: 90 days, duration: 730 days })); // 90-day cliff, 2-year vest

        // Create allocations (multiple beneficiaries, multiple schedules)
        // Alice: schedules 0 and 1
        beneficiaries.push(alice);
        scheduleIds.push(0);
        amounts.push(100_000 ether);

        beneficiaries.push(alice);
        scheduleIds.push(1);
        amounts.push(50_000 ether);

        // Bob: schedules 1 and 2
        beneficiaries.push(bob);
        scheduleIds.push(1);
        amounts.push(80_000 ether);

        beneficiaries.push(bob);
        scheduleIds.push(2);
        amounts.push(120_000 ether);

        // Charlie: schedule 0 only
        beneficiaries.push(charlie);
        scheduleIds.push(0);
        amounts.push(200_000 ether);

        // Deploy token
        token = new DERC20V2(
            "Invariant Test Token",
            "ITT",
            INITIAL_SUPPLY,
            recipient,
            owner,
            YEARLY_MINT_RATE,
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            "https://example.com/token"
        );

        // Create unique beneficiary list for handler
        address[] memory uniqueBeneficiaries = new address[](3);
        uniqueBeneficiaries[0] = alice;
        uniqueBeneficiaries[1] = bob;
        uniqueBeneficiaries[2] = charlie;

        // Deploy handler
        handler = new DERC20V2Handler(token, uniqueBeneficiaries);

        // Configure fuzzer
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.warpTime.selector;
        selectors[1] = handler.releaseFromSchedule.selector;
        selectors[2] = handler.releaseAll.selector;
        selectors[3] = handler.releaseForFromSchedule.selector;
        selectors[4] = handler.releaseForAll.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        // Exclude system addresses from being actors
        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(token));
        excludeSender(owner);
        excludeSender(recipient);
    }

    // =========================================================================
    // Core Invariants
    // =========================================================================

    /**
     * @notice Released amount for any (beneficiary, scheduleId) never exceeds total allocated
     * @dev For all (beneficiary, scheduleId): releasedAmount <= totalAmount
     */
    function invariant_ReleasedNeverExceedsTotalPerSchedule() public view {
        address[] memory beneficiaryList = new address[](3);
        beneficiaryList[0] = alice;
        beneficiaryList[1] = bob;
        beneficiaryList[2] = charlie;

        uint256 scheduleCount = token.vestingScheduleCount();

        for (uint256 i; i < beneficiaryList.length; i++) {
            for (uint256 scheduleId; scheduleId < scheduleCount; scheduleId++) {
                (uint256 totalAmount, uint256 releasedAmount) = token.vestingOf(beneficiaryList[i], scheduleId);
                assertLe(
                    releasedAmount,
                    totalAmount,
                    string.concat(
                        "Released exceeds total for beneficiary ",
                        vm.toString(beneficiaryList[i]),
                        " schedule ",
                        vm.toString(scheduleId)
                    )
                );
            }
        }
    }

    /**
     * @notice Total released across all beneficiaries and schedules never exceeds vestedTotalAmount
     * @dev sum(releasedAmount) <= vestedTotalAmount
     */
    function invariant_TotalReleasedNeverExceedsVestedTotal() public view {
        uint256 contractTotalReleased = handler.getContractTotalReleased();
        uint256 vestedTotal = token.vestedTotalAmount();

        assertLe(contractTotalReleased, vestedTotal, "Total released exceeds vested total amount");
    }

    /**
     * @notice Token contract balance equals vested total minus total released
     * @dev balanceOf(token) == vestedTotalAmount - totalReleased
     */
    function invariant_ContractBalanceMatchesUnreleasedVested() public view {
        uint256 contractBalance = token.balanceOf(address(token));
        uint256 vestedTotal = token.vestedTotalAmount();
        uint256 totalReleased = handler.getContractTotalReleased();

        assertEq(
            contractBalance, vestedTotal - totalReleased, "Contract balance doesn't match unreleased vested amount"
        );
    }

    /**
     * @notice Ghost variable total released matches contract state
     * @dev Validates handler tracking is accurate
     */
    function invariant_GhostReleasedMatchesContractState() public view {
        uint256 ghostTotal = handler.ghost_totalReleased();
        uint256 contractTotal = handler.getContractTotalReleased();

        assertEq(ghostTotal, contractTotal, "Ghost total released doesn't match contract state");
    }

    /**
     * @notice Total supply equals initial supply (no inflation triggered in these tests)
     * @dev totalSupply == INITIAL_SUPPLY (since we don't unlock pool or mint inflation)
     */
    function invariant_TotalSupplyConsistent() public view {
        // Total supply should be initial supply (no inflation minted)
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "Total supply changed unexpectedly");
    }

    /**
     * @notice Available vested amount is always >= 0 and <= (total - released)
     * @dev For all (beneficiary, scheduleId): 0 <= available <= (totalAmount - releasedAmount)
     */
    function invariant_AvailableVestedAmountBounded() public view {
        address[] memory beneficiaryList = new address[](3);
        beneficiaryList[0] = alice;
        beneficiaryList[1] = bob;
        beneficiaryList[2] = charlie;

        uint256 scheduleCount = token.vestingScheduleCount();

        for (uint256 i; i < beneficiaryList.length; i++) {
            for (uint256 scheduleId; scheduleId < scheduleCount; scheduleId++) {
                (uint256 totalAmount, uint256 releasedAmount) = token.vestingOf(beneficiaryList[i], scheduleId);
                uint256 available = token.computeAvailableVestedAmount(beneficiaryList[i], scheduleId);

                // Available should never exceed remaining
                uint256 remaining = totalAmount - releasedAmount;
                assertLe(available, remaining, "Available exceeds remaining");
            }
        }
    }

    /**
     * @notice Vesting schedules are immutable after construction
     * @dev Schedule parameters should never change
     */
    function invariant_VestingSchedulesImmutable() public view {
        // Schedule 0: 30 days cliff, 365 days duration
        (uint64 cliff0, uint64 duration0) = token.vestingSchedules(0);
        assertEq(cliff0, 30 days, "Schedule 0 cliff changed");
        assertEq(duration0, 365 days, "Schedule 0 duration changed");

        // Schedule 1: 0 cliff, 180 days duration
        (uint64 cliff1, uint64 duration1) = token.vestingSchedules(1);
        assertEq(cliff1, 0, "Schedule 1 cliff changed");
        assertEq(duration1, 180 days, "Schedule 1 duration changed");

        // Schedule 2: 90 days cliff, 730 days duration
        (uint64 cliff2, uint64 duration2) = token.vestingSchedules(2);
        assertEq(cliff2, 90 days, "Schedule 2 cliff changed");
        assertEq(duration2, 730 days, "Schedule 2 duration changed");
    }

    /**
     * @notice Total allocated per beneficiary matches cap constraints
     * @dev totalAllocatedOf[beneficiary] == sum of allocations for that beneficiary
     */
    function invariant_TotalAllocatedConsistent() public view {
        address[] memory beneficiaryList = new address[](3);
        beneficiaryList[0] = alice;
        beneficiaryList[1] = bob;
        beneficiaryList[2] = charlie;

        for (uint256 i; i < beneficiaryList.length; i++) {
            address beneficiary = beneficiaryList[i];
            uint256 storedTotal = token.totalAllocatedOf(beneficiary);
            uint256 computedTotal = handler.getTotalAllocatedOf(beneficiary);

            assertEq(
                storedTotal, computedTotal, string.concat("Total allocated mismatch for ", vm.toString(beneficiary))
            );
        }
    }

    /**
     * @notice Vesting start time is immutable
     */
    function invariant_VestingStartImmutable() public view {
        // vestingStart should be the deployment timestamp
        // Since we can't easily capture it, just verify it's non-zero and in the past
        uint256 vestingStart = token.vestingStart();
        assertGt(vestingStart, 0, "Vesting start is zero");
        assertLe(vestingStart, block.timestamp, "Vesting start is in the future");
    }

    // =========================================================================
    // Call Summary (for debugging)
    // =========================================================================

    function invariant_callSummary() public view {
        // This invariant always passes but logs useful stats
        // console.log("Release calls:", handler.ghost_releaseCallCount());
        // console.log("Release reverts:", handler.ghost_releaseRevertCount());
        // console.log("Total released:", handler.ghost_totalReleased());
        // console.log("Last warp:", handler.ghost_lastWarp());
    }
}
