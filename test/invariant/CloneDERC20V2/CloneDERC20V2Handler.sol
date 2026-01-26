// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { CloneDERC20V2, NoReleasableAmount, VestingData, VestingSchedule } from "src/tokens/CloneDERC20V2.sol";

/**
 * @title DERC20V2Handler
 * @notice Handler for invariant testing of CloneDERC20V2 multi-schedule vesting
 * @dev Exposes bounded actions and tracks ghost variables for invariant assertions
 */
contract CloneDERC20V2Handler is Test {
    CloneDERC20V2 public token;

    // =========================================================================
    // Ghost Variables (mimic expected state for invariant checks)
    // =========================================================================

    /// @notice Total tokens released across all beneficiaries and schedules
    uint256 public ghost_totalReleased;

    /// @notice Tracks released amount per (beneficiary, scheduleId) pair
    mapping(address => mapping(uint256 => uint256)) public ghost_releasedOf;

    /// @notice Tracks the last warp timestamp
    uint256 public ghost_lastWarp;

    address internal _currentActor;

    // =========================================================================
    // Actor Management
    // =========================================================================

    address[] public beneficiaries;
    uint256 public scheduleCount;

    modifier useBeneficiary() {
        _currentActor = beneficiaries[vm.randomUint(0, beneficiaries.length - 1)];
        vm.startPrank(_currentActor);
        _;
        vm.stopPrank();
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(CloneDERC20V2 token_, address[] memory beneficiaries_) {
        token = token_;
        beneficiaries = beneficiaries_;
        scheduleCount = token.vestingScheduleCount();
        ghost_lastWarp = block.timestamp;
    }

    // =========================================================================
    // Handler Actions
    // =========================================================================

    /**
     * @notice Warps time forward by a bounded amount
     * @param deltaSeed Seed to derive time delta (bounded to reasonable range)
     */
    function warpTime(uint256 deltaSeed) external {
        // Bound delta between 1 second and 365 days
        uint256 delta = bound(deltaSeed, 1, 365 days);
        vm.warp(block.timestamp + delta);
        ghost_lastWarp = block.timestamp;
    }

    /**
     * @notice Beneficiary releases from a specific schedule
     * @param scheduleIdSeed Seed to select schedule ID
     */
    function releaseFromSchedule(uint256 scheduleIdSeed) external useBeneficiary {
        if (scheduleCount == 0) return;

        uint256 scheduleId = scheduleIdSeed % scheduleCount;
        uint256 availableBefore = token.computeAvailableVestedAmount(_currentActor, scheduleId);

        if (availableBefore == 0) {
            // Expect revert
            vm.expectRevert(NoReleasableAmount.selector);
            token.release(scheduleId);
            return;
        }

        uint256 balanceBefore = token.balanceOf(_currentActor);
        token.release(scheduleId);
        uint256 balanceAfter = token.balanceOf(_currentActor);

        uint256 released = balanceAfter - balanceBefore;
        ghost_totalReleased += released;
        ghost_releasedOf[_currentActor][scheduleId] += released;
    }

    /**
     * @notice Beneficiary releases from all schedules
     */
    function releaseAll() external useBeneficiary {
        uint256 availableBefore = token.computeAvailableVestedAmount(_currentActor);

        if (availableBefore == 0) {
            // Expect revert
            vm.expectRevert(NoReleasableAmount.selector);
            token.release();
            return;
        }

        uint256 balanceBefore = token.balanceOf(_currentActor);

        // Track per-schedule releases before
        uint256[] memory scheduleIds = token.getScheduleIdsOf(_currentActor);
        uint256[] memory availablePerSchedule = new uint256[](scheduleIds.length);
        for (uint256 i; i < scheduleIds.length; i++) {
            availablePerSchedule[i] = token.computeAvailableVestedAmount(_currentActor, scheduleIds[i]);
        }

        token.release();

        uint256 balanceAfter = token.balanceOf(_currentActor);
        uint256 totalReleased = balanceAfter - balanceBefore;

        // Update ghost variables
        ghost_totalReleased += totalReleased;
        for (uint256 i; i < scheduleIds.length; i++) {
            ghost_releasedOf[_currentActor][scheduleIds[i]] += availablePerSchedule[i];
        }
    }

    /**
     * @notice Third party releases for a beneficiary from a specific schedule
     * @param actorSeed Seed to select actor (caller)
     * @param beneficiaryIndex Index into beneficiary list
     * @param scheduleIdSeed Seed to select schedule ID
     */
    function releaseForFromSchedule(uint256 actorSeed, uint256 beneficiaryIndex, uint256 scheduleIdSeed) external {
        if (beneficiaries.length == 0 || scheduleCount == 0) return;

        address beneficiary = beneficiaries[beneficiaryIndex % beneficiaries.length];
        uint256 scheduleId = scheduleIdSeed % scheduleCount;
        uint256 availableBefore = token.computeAvailableVestedAmount(beneficiary, scheduleId);

        if (availableBefore == 0) {
            vm.expectRevert(NoReleasableAmount.selector);
            token.releaseFor(beneficiary, scheduleId);
            return;
        }

        uint256 balanceBefore = token.balanceOf(beneficiary);
        token.releaseFor(beneficiary, scheduleId);
        uint256 balanceAfter = token.balanceOf(beneficiary);

        uint256 released = balanceAfter - balanceBefore;
        ghost_totalReleased += released;
        ghost_releasedOf[beneficiary][scheduleId] += released;
    }

    /**
     * @notice Third party releases for a beneficiary from all schedules
     * @param beneficiaryIndex Index into beneficiary list
     */
    function releaseForAll(uint256 beneficiaryIndex) external {
        if (beneficiaries.length == 0) return;

        address beneficiary = beneficiaries[beneficiaryIndex % beneficiaries.length];
        uint256 availableBefore = token.computeAvailableVestedAmount(beneficiary);

        if (availableBefore == 0) {
            vm.expectRevert();
            token.releaseFor(beneficiary);
            return;
        }

        uint256 balanceBefore = token.balanceOf(beneficiary);

        // Track per-schedule releases before
        uint256[] memory scheduleIds = token.getScheduleIdsOf(beneficiary);
        uint256[] memory availablePerSchedule = new uint256[](scheduleIds.length);
        for (uint256 i; i < scheduleIds.length; i++) {
            availablePerSchedule[i] = token.computeAvailableVestedAmount(beneficiary, scheduleIds[i]);
        }

        token.releaseFor(beneficiary);

        uint256 balanceAfter = token.balanceOf(beneficiary);
        uint256 totalReleased = balanceAfter - balanceBefore;

        ghost_totalReleased += totalReleased;
        for (uint256 i; i < scheduleIds.length; i++) {
            ghost_releasedOf[beneficiary][scheduleIds[i]] += availablePerSchedule[i];
        }
    }

    // =========================================================================
    // View Helpers (for invariant assertions)
    // =========================================================================

    /// @notice Returns the total released amount tracked by the contract
    function getContractTotalReleased() external view returns (uint256 total) {
        for (uint256 i; i < beneficiaries.length; i++) {
            address beneficiary = beneficiaries[i];
            uint256[] memory scheduleIds = token.getScheduleIdsOf(beneficiary);
            for (uint256 j; j < scheduleIds.length; j++) {
                (, uint256 releasedAmount) = token.vestingOf(beneficiary, scheduleIds[j]);
                total += releasedAmount;
            }
        }
    }

    /// @notice Returns the total allocated amount for a beneficiary
    function getTotalAllocatedOf(address beneficiary) external view returns (uint256 total) {
        uint256[] memory scheduleIds = token.getScheduleIdsOf(beneficiary);
        for (uint256 i; i < scheduleIds.length; i++) {
            (uint256 totalAmount,) = token.vestingOf(beneficiary, scheduleIds[i]);
            total += totalAmount;
        }
    }

    /// @notice Returns beneficiary count
    function getBeneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }

    // =========================================================================
    // Internal Stuff
    // =========================================================================

    function _setUp(uint256 seed) internal { }
}
