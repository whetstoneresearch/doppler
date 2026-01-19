// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DERC20V2, VestingData, VestingSchedule } from "src/tokens/DERC20V2.sol";
import { AddressSet, LibAddressSet } from "test/invariant/AddressSet.sol";

/**
 * @title DERC20V2Handler
 * @notice Handler for invariant testing of DERC20V2 multi-schedule vesting
 * @dev Exposes bounded actions and tracks ghost variables for invariant assertions
 */
contract DERC20V2Handler is Test {
    using LibAddressSet for AddressSet;

    DERC20V2 public token;

    // =========================================================================
    // Ghost Variables (mimic expected state for invariant checks)
    // =========================================================================

    /// @notice Total tokens released across all beneficiaries and schedules
    uint256 public ghost_totalReleased;

    /// @notice Tracks released amount per (beneficiary, scheduleId) pair
    mapping(address => mapping(uint256 => uint256)) public ghost_releasedOf;

    /// @notice Number of successful release() calls
    uint256 public ghost_releaseCallCount;

    /// @notice Number of failed release() calls (reverted with NoReleasableAmount)
    uint256 public ghost_releaseRevertCount;

    /// @notice Tracks the last warp timestamp
    uint256 public ghost_lastWarp;

    // =========================================================================
    // Actor Management
    // =========================================================================

    AddressSet internal _beneficiaries;
    AddressSet internal _actors;
    address internal _currentActor;

    address[] public beneficiaryList;
    uint256 public scheduleCount;

    modifier useActor(uint256 actorSeed) {
        if (_actors.count() == 0) return;
        _currentActor = _actors.rand(actorSeed);
        vm.startPrank(_currentActor);
        _;
        vm.stopPrank();
    }

    modifier useBeneficiary(uint256 beneficiarySeed) {
        if (_beneficiaries.count() == 0) return;
        _currentActor = _beneficiaries.rand(beneficiarySeed);
        vm.startPrank(_currentActor);
        _;
        vm.stopPrank();
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(DERC20V2 token_, address[] memory beneficiaries_) {
        token = token_;
        beneficiaryList = beneficiaries_;
        scheduleCount = token.vestingScheduleCount();
        ghost_lastWarp = block.timestamp;

        // Register beneficiaries
        for (uint256 i; i < beneficiaries_.length; i++) {
            _beneficiaries.add(beneficiaries_[i]);
            _actors.add(beneficiaries_[i]);
        }
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
     * @param beneficiarySeed Seed to select beneficiary
     * @param scheduleIdSeed Seed to select schedule ID
     */
    function releaseFromSchedule(
        uint256 beneficiarySeed,
        uint256 scheduleIdSeed
    ) external useBeneficiary(beneficiarySeed) {
        if (scheduleCount == 0) return;

        uint256 scheduleId = scheduleIdSeed % scheduleCount;
        uint256 availableBefore = token.computeAvailableVestedAmount(_currentActor, scheduleId);

        if (availableBefore == 0) {
            // Expect revert
            vm.expectRevert();
            token.release(scheduleId);
            ghost_releaseRevertCount++;
            return;
        }

        uint256 balanceBefore = token.balanceOf(_currentActor);
        token.release(scheduleId);
        uint256 balanceAfter = token.balanceOf(_currentActor);

        uint256 released = balanceAfter - balanceBefore;
        ghost_totalReleased += released;
        ghost_releasedOf[_currentActor][scheduleId] += released;
        ghost_releaseCallCount++;
    }

    /**
     * @notice Beneficiary releases from all schedules
     * @param beneficiarySeed Seed to select beneficiary
     */
    function releaseAll(uint256 beneficiarySeed) external useBeneficiary(beneficiarySeed) {
        uint256 availableBefore = token.computeAvailableVestedAmount(_currentActor);

        if (availableBefore == 0) {
            // Expect revert
            vm.expectRevert();
            token.release();
            ghost_releaseRevertCount++;
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
        ghost_releaseCallCount++;
    }

    /**
     * @notice Third party releases for a beneficiary from a specific schedule
     * @param actorSeed Seed to select actor (caller)
     * @param beneficiaryIndex Index into beneficiary list
     * @param scheduleIdSeed Seed to select schedule ID
     */
    function releaseForFromSchedule(
        uint256 actorSeed,
        uint256 beneficiaryIndex,
        uint256 scheduleIdSeed
    ) external useActor(actorSeed) {
        if (beneficiaryList.length == 0 || scheduleCount == 0) return;

        address beneficiary = beneficiaryList[beneficiaryIndex % beneficiaryList.length];
        uint256 scheduleId = scheduleIdSeed % scheduleCount;
        uint256 availableBefore = token.computeAvailableVestedAmount(beneficiary, scheduleId);

        if (availableBefore == 0) {
            vm.expectRevert();
            token.releaseFor(beneficiary, scheduleId);
            ghost_releaseRevertCount++;
            return;
        }

        uint256 balanceBefore = token.balanceOf(beneficiary);
        token.releaseFor(beneficiary, scheduleId);
        uint256 balanceAfter = token.balanceOf(beneficiary);

        uint256 released = balanceAfter - balanceBefore;
        ghost_totalReleased += released;
        ghost_releasedOf[beneficiary][scheduleId] += released;
        ghost_releaseCallCount++;
    }

    /**
     * @notice Third party releases for a beneficiary from all schedules
     * @param actorSeed Seed to select actor (caller)
     * @param beneficiaryIndex Index into beneficiary list
     */
    function releaseForAll(uint256 actorSeed, uint256 beneficiaryIndex) external useActor(actorSeed) {
        if (beneficiaryList.length == 0) return;

        address beneficiary = beneficiaryList[beneficiaryIndex % beneficiaryList.length];
        uint256 availableBefore = token.computeAvailableVestedAmount(beneficiary);

        if (availableBefore == 0) {
            vm.expectRevert();
            token.releaseFor(beneficiary);
            ghost_releaseRevertCount++;
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
        ghost_releaseCallCount++;
    }

    // =========================================================================
    // View Helpers (for invariant assertions)
    // =========================================================================

    /// @notice Returns the total released amount tracked by the contract
    function getContractTotalReleased() external view returns (uint256 total) {
        for (uint256 i; i < beneficiaryList.length; i++) {
            address beneficiary = beneficiaryList[i];
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
        return beneficiaryList.length;
    }
}
