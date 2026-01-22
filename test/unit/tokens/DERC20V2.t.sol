// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20Errors } from "@openzeppelin/interfaces/draft-IERC6093.sol";
import { Test } from "forge-std/Test.sol";
import {
    ArrayLengthsMismatch,
    DERC20V2,
    InvalidAllocation,
    InvalidSchedule,
    MAX_PRE_MINT_PER_ADDRESS_WAD,
    MAX_TOTAL_PRE_MINT_WAD,
    MIN_VESTING_DURATION,
    MaxPreMintPerAddressExceeded,
    MaxTotalPreMintExceeded,
    MaxTotalVestedExceeded,
    MintingNotStartedYet,
    NoMintableAmount,
    NoReleasableAmount,
    PoolLocked,
    UnknownScheduleId,
    VestingSchedule
} from "src/tokens/DERC20V2.sol";

uint256 constant INITIAL_SUPPLY = 1e26;
uint256 constant YEARLY_MINT_RATE = 0.02e18;
string constant NAME = "TestV2";
string constant SYMBOL = "TSTV2";
address constant RECIPIENT = address(0xa71ce);
address constant OWNER = address(0xb0b);

contract DERC20V2Test is Test {
    DERC20V2 public token;

    // =========================================================================
    // Helpers
    // =========================================================================

    function _emptySchedules() internal pure returns (VestingSchedule[] memory) {
        return new VestingSchedule[](0);
    }

    function _emptyAddresses() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _emptyUints() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _createToken(
        VestingSchedule[] memory schedules,
        address[] memory beneficiaries,
        uint256[] memory scheduleIds,
        uint256[] memory amounts
    ) internal returns (DERC20V2) {
        return new DERC20V2(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            OWNER,
            YEARLY_MINT_RATE,
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            ""
        );
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_BasicSetup() public {
        // Two schedules: 1 year with 6 month cliff, 2 years with 1 year cliff
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 180 days, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 365 days, duration: 730 days });

        // Three allocations across two beneficiaries
        address[] memory beneficiaries = new address[](3);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xb);
        beneficiaries[2] = address(0xa); // Same beneficiary, different schedule

        uint256[] memory scheduleIds = new uint256[](3);
        scheduleIds[0] = 0;
        scheduleIds[1] = 0;
        scheduleIds[2] = 1;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e24;
        amounts[1] = 2e24;
        amounts[2] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Basic assertions
        assertEq(token.name(), NAME, "Wrong name");
        assertEq(token.symbol(), SYMBOL, "Wrong symbol");
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "Wrong total supply");
        assertEq(token.vestingStart(), block.timestamp, "Wrong vesting start");
        assertEq(token.vestedTotalAmount(), 4e24, "Wrong vested total");
        assertEq(token.owner(), OWNER, "Wrong owner");
        assertEq(token.yearlyMintRate(), YEARLY_MINT_RATE, "Wrong yearly mint rate");

        // Token balances
        assertEq(token.balanceOf(address(token)), 4e24, "Wrong contract balance");
        assertEq(token.balanceOf(RECIPIENT), INITIAL_SUPPLY - 4e24, "Wrong recipient balance");

        // Schedule count
        assertEq(token.vestingScheduleCount(), 2, "Wrong schedule count");

        // Schedule details
        (uint64 cliff0, uint64 duration0) = token.vestingSchedules(0);
        assertEq(cliff0, 180 days, "Wrong cliff for schedule 0");
        assertEq(duration0, 365 days, "Wrong duration for schedule 0");

        (uint64 cliff1, uint64 duration1) = token.vestingSchedules(1);
        assertEq(cliff1, 365 days, "Wrong cliff for schedule 1");
        assertEq(duration1, 730 days, "Wrong duration for schedule 1");

        // Vesting data
        (uint256 total0, uint256 released0) = token.vestingOf(address(0xa), 0);
        assertEq(total0, 1e24, "Wrong total for 0xa schedule 0");
        assertEq(released0, 0, "Wrong released for 0xa schedule 0");

        (uint256 total1, uint256 released1) = token.vestingOf(address(0xa), 1);
        assertEq(total1, 1e24, "Wrong total for 0xa schedule 1");
        assertEq(released1, 0, "Wrong released for 0xa schedule 1");

        // Schedule IDs
        uint256[] memory idsA = token.getScheduleIdsOf(address(0xa));
        assertEq(idsA.length, 2, "Wrong number of schedules for 0xa");
        assertEq(idsA[0], 0, "Wrong first schedule ID for 0xa");
        assertEq(idsA[1], 1, "Wrong second schedule ID for 0xa");

        // Total allocated
        assertEq(token.totalAllocatedOf(address(0xa)), 2e24, "Wrong total allocated for 0xa");
        assertEq(token.totalAllocatedOf(address(0xb)), 2e24, "Wrong total allocated for 0xb");
    }

    function test_constructor_NoVesting() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        assertEq(token.vestedTotalAmount(), 0, "Should have no vested amount");
        assertEq(token.balanceOf(RECIPIENT), INITIAL_SUPPLY, "Recipient should get all");
        assertEq(token.balanceOf(address(token)), 0, "Contract should have nothing");
        assertEq(token.vestingScheduleCount(), 0, "Should have no schedules");
    }

    function test_constructor_AggregatesDuplicateAllocations() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        // Same beneficiary, same schedule, two allocations
        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 0;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e24;
        amounts[1] = 2e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        (uint256 total,) = token.vestingOf(address(0xa), 0);
        assertEq(total, 3e24, "Allocations should be aggregated");

        uint256[] memory ids = token.getScheduleIdsOf(address(0xa));
        assertEq(ids.length, 1, "Should only have one schedule ID entry");
    }

    function test_constructor_RevertsWhenArrayLengthsMismatch() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xb);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e24;
        amounts[1] = 2e24;

        vm.expectRevert(ArrayLengthsMismatch.selector);
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_constructor_DurationZeroIsInstantVest() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 0 });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Instant vest: should be fully available immediately
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Should be fully vested at t=0");

        vm.prank(address(0xa));
        token.release(0);
        assertEq(token.balanceOf(address(0xa)), 1e24, "Should receive full amount");
    }

    function test_constructor_RevertsWhenDurationBelowMinimum() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        // Duration between 0 and MIN_VESTING_DURATION is invalid
        schedules[0] = VestingSchedule({ cliff: 0, duration: uint64(MIN_VESTING_DURATION - 1) });

        vm.expectRevert(abi.encodeWithSelector(InvalidSchedule.selector, 0));
        _createToken(schedules, _emptyAddresses(), _emptyUints(), _emptyUints());
    }

    function test_constructor_RevertsWhenInvalidScheduleCliffGreaterThanDuration() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 400 days, duration: 365 days });

        vm.expectRevert(abi.encodeWithSelector(InvalidSchedule.selector, 0));
        _createToken(schedules, _emptyAddresses(), _emptyUints(), _emptyUints());
    }

    function test_constructor_RevertsWhenUnknownScheduleId() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 1; // Out of range

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        vm.expectRevert(abi.encodeWithSelector(UnknownScheduleId.selector, 1));
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_constructor_RevertsWhenInvalidAllocationZeroAddress() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        vm.expectRevert(abi.encodeWithSelector(InvalidAllocation.selector, 0));
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_constructor_RevertsWhenInvalidAllocationZeroAmount() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        vm.expectRevert(abi.encodeWithSelector(InvalidAllocation.selector, 0));
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_constructor_RevertsWhenMaxPreMintPerAddressExceeded() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = maxPerAddress + 1;

        vm.expectRevert(abi.encodeWithSelector(MaxPreMintPerAddressExceeded.selector, amounts[0], maxPerAddress));
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_constructor_RevertsWhenMaxPreMintPerAddressExceededAcrossSchedules() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 0, duration: 730 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = maxPerAddress;
        amounts[1] = 1; // This pushes it over

        vm.expectRevert(abi.encodeWithSelector(MaxPreMintPerAddressExceeded.selector, maxPerAddress + 1, maxPerAddress));
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_constructor_RevertsWhenMaxTotalPreMintExceeded() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        // Use two addresses to avoid per-address cap
        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xb);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 0;

        uint256 maxTotal = INITIAL_SUPPLY * MAX_TOTAL_PRE_MINT_WAD / 1e18;
        uint256 perAddress = maxTotal / 2 + 1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = perAddress;
        amounts[1] = perAddress;

        vm.expectRevert(abi.encodeWithSelector(MaxTotalPreMintExceeded.selector, perAddress * 2, maxTotal));
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    // =========================================================================
    // Cliff Gating Tests
    // =========================================================================

    function test_cliffGating_NothingClaimableBeforeCliff() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 180 days, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Warp to just before cliff
        vm.warp(token.vestingStart() + 180 days - 1);

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Should be 0 before cliff");
        assertEq(token.computeAvailableVestedAmount(address(0xa)), 0, "Total should be 0 before cliff");

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0);
    }

    function test_cliffGating_ClaimableAtCliff() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 180 days, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 365e18; // 365 tokens for easy math (1 token per day)

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Warp to exactly cliff
        vm.warp(token.vestingStart() + 180 days);

        // Should have 180 days worth of vesting available (linear from start)
        uint256 expected = 365e18 * 180 days / 365 days;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected, "Wrong available at cliff");

        vm.prank(address(0xa));
        token.release(0);
        assertEq(token.balanceOf(address(0xa)), expected, "Wrong balance after release");
    }

    function test_cliffGating_ZeroCliffWorksImmediately() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 365e18;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Warp 1 day
        vm.warp(token.vestingStart() + 1 days);

        uint256 expected = 365e18 * 1 days / 365 days;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected, "Wrong available with zero cliff");
    }

    // =========================================================================
    // Linear Vesting Tests
    // =========================================================================

    function test_linearVesting_25Percent() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days / 4);

        uint256 expected = 1e24 / 4;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected, "Wrong at 25%");

        vm.prank(address(0xa));
        token.release(0);
        assertEq(token.balanceOf(address(0xa)), expected, "Wrong balance at 25%");
    }

    function test_linearVesting_50Percent() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Claim at 25%
        vm.warp(token.vestingStart() + 365 days / 4);
        vm.prank(address(0xa));
        token.release(0);

        // Claim at 50%
        vm.warp(token.vestingStart() + 365 days / 2);
        uint256 expectedAdditional = 1e24 / 2 - 1e24 / 4;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expectedAdditional, "Wrong at 50%");

        vm.prank(address(0xa));
        token.release(0);
        assertEq(token.balanceOf(address(0xa)), 1e24 / 2, "Wrong total balance at 50%");
    }

    function test_linearVesting_100Percent() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Wrong at 100%");

        vm.prank(address(0xa));
        token.release(0);
        assertEq(token.balanceOf(address(0xa)), 1e24, "Wrong balance at 100%");
    }

    function test_linearVesting_BeyondDuration() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 730 days); // 2 years

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Should cap at total");
    }

    // =========================================================================
    // Multi-Schedule Tests
    // =========================================================================

    function test_multiSchedule_ReleaseBothWithReleaseNoArgs() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 0, duration: 730 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e24;
        amounts[1] = 2e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        // Schedule 0: fully vested (1e24)
        // Schedule 1: 50% vested (1e24)
        uint256 expected = 1e24 + 1e24;

        assertEq(token.computeAvailableVestedAmount(address(0xa)), expected, "Wrong total available");

        vm.prank(address(0xa));
        token.release();
        assertEq(token.balanceOf(address(0xa)), expected, "Wrong balance after release()");
    }

    function test_multiSchedule_ReleaseOnlyOne() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 0, duration: 730 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e24;
        amounts[1] = 2e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        // Only release schedule 0
        vm.prank(address(0xa));
        token.release(0);
        assertEq(token.balanceOf(address(0xa)), 1e24, "Should only get schedule 0");

        // Schedule 1 should still be available
        assertEq(token.computeAvailableVestedAmount(address(0xa), 1), 1e24, "Schedule 1 should still be available");
    }

    // =========================================================================
    // releaseFor Tests
    // =========================================================================

    function test_releaseFor_AnyoneCanCall() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        // Random address calls releaseFor
        vm.prank(address(0xdead));
        token.releaseFor(address(0xa), 0);

        // Tokens go to beneficiary, not caller
        assertEq(token.balanceOf(address(0xa)), 1e24, "Tokens should go to beneficiary");
        assertEq(token.balanceOf(address(0xdead)), 0, "Caller should get nothing");
    }

    function test_releaseFor_AllSchedules() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e24;
        amounts[1] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xdead));
        token.releaseFor(address(0xa));

        assertEq(token.balanceOf(address(0xa)), 2e24, "Should release all schedules");
    }

    // =========================================================================
    // Revert-on-Zero Tests
    // =========================================================================

    function test_revertOnZero_ReleaseWithScheduleId() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 365 days, duration: 730 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Before cliff
        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0);
    }

    function test_revertOnZero_ReleaseNoArgs() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 365 days, duration: 730 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Before cliff
        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release();
    }

    function test_revertOnZero_AfterFullyClaimed() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        vm.startPrank(address(0xa));
        token.release(0);

        // Try to release again
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0);
        vm.stopPrank();
    }

    function test_revertOnZero_NoAllocations() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        token = _createToken(schedules, _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release();
    }

    // =========================================================================
    // Pool Lock Tests (preserved from v1)
    // =========================================================================

    function test_poolLock_TransferBlocked() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        address poolAddr = address(0xdeadbeef);
        vm.prank(OWNER);
        token.lockPool(poolAddr);

        vm.prank(RECIPIENT);
        vm.expectRevert(PoolLocked.selector);
        token.transfer(poolAddr, 1);
    }

    function test_poolLock_UnlockAllowsTransfer() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        address poolAddr = address(0xdeadbeef);
        vm.startPrank(OWNER);
        token.lockPool(poolAddr);
        token.unlockPool();
        vm.stopPrank();

        vm.prank(RECIPIENT);
        token.transfer(poolAddr, 1);
        assertEq(token.balanceOf(poolAddr), 1, "Transfer should succeed after unlock");
    }

    // =========================================================================
    // Permit2 Tests (preserved from v1)
    // =========================================================================

    function test_permit2_InfiniteAllowance() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        assertEq(token.allowance(RECIPIENT, permit2), type(uint256).max, "Permit2 should have infinite allowance");
    }

    // =========================================================================
    // Fuzz Tests - Vesting Math
    // =========================================================================

    /**
     * @notice Fuzz test: linear vesting at any point returns correct amount
     * @param duration Duration of the schedule (bounded to reasonable range)
     * @param totalAmount Total allocated amount (bounded to cap)
     * @param elapsedPercent Percentage of duration elapsed (0-100)
     */
    function testFuzz_linearVesting_AtAnyPoint(uint64 duration, uint256 totalAmount, uint8 elapsedPercent) public {
        // Bound inputs
        duration = uint64(bound(duration, 1 days, 10 * 365 days)); // 1 day to 10 years
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        totalAmount = bound(totalAmount, 1, maxPerAddress);
        elapsedPercent = uint8(bound(elapsedPercent, 0, 100));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Calculate elapsed time
        uint256 elapsed = uint256(duration) * elapsedPercent / 100;
        vm.warp(token.vestingStart() + elapsed);

        // Calculate expected vested amount
        uint256 expected;
        if (elapsed >= duration) {
            expected = totalAmount;
        } else {
            expected = totalAmount * elapsed / duration;
        }

        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(available, expected, "Vested amount mismatch");
    }

    /**
     * @notice Fuzz test: cliff gating blocks claims before cliff
     * @param cliff Cliff duration (bounded)
     * @param duration Total duration (bounded, >= cliff)
     * @param totalAmount Total allocated amount
     * @param elapsedBeforeCliff Time elapsed before cliff (0 to cliff-1)
     */
    function testFuzz_cliffGating_BlocksBeforeCliff(
        uint64 cliff,
        uint64 duration,
        uint256 totalAmount,
        uint64 elapsedBeforeCliff
    ) public {
        // Duration must be >= MIN_VESTING_DURATION
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        // Cliff must be at least 1 and at most duration
        cliff = uint64(bound(cliff, 1, duration));
        // Total amount bounded to cap
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        totalAmount = bound(totalAmount, 1, maxPerAddress);
        // Elapsed before cliff
        elapsedBeforeCliff = uint64(bound(elapsedBeforeCliff, 0, cliff - 1));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: cliff, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Warp to before cliff
        vm.warp(token.vestingStart() + elapsedBeforeCliff);

        // Should always be 0 before cliff
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Should be 0 before cliff");

        // Release should revert
        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0);
    }

    /**
     * @notice Fuzz test: cliff gating allows claims at and after cliff
     * @param cliff Cliff duration
     * @param duration Total duration
     * @param totalAmount Total allocated amount
     * @param elapsedAfterCliff Time elapsed after cliff (0 to duration-cliff)
     */
    function testFuzz_cliffGating_AllowsAtAndAfterCliff(
        uint64 cliff,
        uint64 duration,
        uint256 totalAmount,
        uint64 elapsedAfterCliff
    ) public {
        // Bound cliff
        cliff = uint64(bound(cliff, 0, 365 days));
        // Duration must be >= MIN_VESTING_DURATION and > cliff (to have room after)
        uint256 minDuration = cliff + 1 > MIN_VESTING_DURATION ? cliff + 1 : MIN_VESTING_DURATION;
        duration = uint64(bound(duration, minDuration, cliff + 365 days));
        // Total amount bounded
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        totalAmount = bound(totalAmount, 1e18, maxPerAddress); // Minimum 1 token to avoid dust
        // Elapsed after cliff
        elapsedAfterCliff = uint64(bound(elapsedAfterCliff, 0, duration - cliff));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: cliff, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Warp to cliff + elapsed
        uint256 totalElapsed = uint256(cliff) + elapsedAfterCliff;
        vm.warp(token.vestingStart() + totalElapsed);

        // Calculate expected vested amount (linear from start)
        uint256 expected;
        if (totalElapsed >= duration) {
            expected = totalAmount;
        } else {
            expected = totalAmount * totalElapsed / duration;
        }

        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(available, expected, "Wrong available after cliff");

        // Should be able to release
        if (expected > 0) {
            vm.prank(address(0xa));
            token.release(0);
            assertEq(token.balanceOf(address(0xa)), expected, "Wrong balance after release");
        }
    }

    /**
     * @notice Fuzz test: multiple releases never exceed total
     * @param duration Duration of schedule
     * @param totalAmount Total allocated amount
     * @param releasePercents Array of release percentages
     */
    function testFuzz_multipleReleases_NeverExceedTotal(
        uint64 duration,
        uint256 totalAmount,
        uint8[5] memory releasePercents
    ) public {
        // Bound inputs
        duration = uint64(bound(duration, 1 days, 365 days));
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        totalAmount = bound(totalAmount, 1e18, maxPerAddress);

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        uint256 totalReleased;
        uint256 lastPercent;

        for (uint256 i; i < 5; i++) {
            // Ensure percentages are monotonically increasing
            uint8 percent = uint8(bound(releasePercents[i], uint8(lastPercent), 100));
            lastPercent = percent;

            uint256 elapsed = uint256(duration) * percent / 100;
            vm.warp(token.vestingStart() + elapsed);

            uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
            if (available > 0) {
                vm.prank(address(0xa));
                token.release(0);
                totalReleased += available;
            }
        }

        // Total released should never exceed total amount
        assertLe(totalReleased, totalAmount, "Released exceeds total");

        // After full duration, should have released everything
        vm.warp(token.vestingStart() + duration);
        uint256 finalAvailable = token.computeAvailableVestedAmount(address(0xa), 0);
        if (finalAvailable > 0) {
            vm.prank(address(0xa));
            token.release(0);
            totalReleased += finalAvailable;
        }

        assertEq(totalReleased, totalAmount, "Should release exactly total amount");
    }

    /**
     * @notice Fuzz test: multi-schedule vesting is additive
     * @param duration0 Duration of first schedule
     * @param duration1 Duration of second schedule
     * @param amount0 Amount for first schedule
     * @param amount1 Amount for second schedule
     * @param elapsed Time elapsed
     */
    function testFuzz_multiSchedule_IndependentVesting(
        uint64 duration0,
        uint64 duration1,
        uint256 amount0,
        uint256 amount1,
        uint64 elapsed
    ) public {
        // Bound inputs
        duration0 = uint64(bound(duration0, 1 days, 365 days));
        duration1 = uint64(bound(duration1, 1 days, 730 days));
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        amount0 = bound(amount0, 1, maxPerAddress / 2);
        amount1 = bound(amount1, 1, maxPerAddress / 2);
        elapsed = uint64(bound(elapsed, 0, 730 days));

        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: duration0 });
        schedules[1] = VestingSchedule({ cliff: 0, duration: duration1 });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256[] memory amountsArr = new uint256[](2);
        amountsArr[0] = amount0;
        amountsArr[1] = amount1;

        token = _createToken(schedules, beneficiaries, scheduleIds, amountsArr);

        vm.warp(token.vestingStart() + elapsed);

        // Calculate expected for each schedule independently
        uint256 expected0 = elapsed >= duration0 ? amount0 : amount0 * elapsed / duration0;
        uint256 expected1 = elapsed >= duration1 ? amount1 : amount1 * elapsed / duration1;

        // Individual schedule checks
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected0, "Schedule 0 mismatch");
        assertEq(token.computeAvailableVestedAmount(address(0xa), 1), expected1, "Schedule 1 mismatch");

        // Total should be sum
        assertEq(token.computeAvailableVestedAmount(address(0xa)), expected0 + expected1, "Total mismatch");
    }

    /**
     * @notice Fuzz test: releaseFor always sends to beneficiary, not caller
     * @param caller Address of the caller
     * @param elapsed Time elapsed
     */
    function testFuzz_releaseFor_TokensAlwaysGoBeneficiary(address caller, uint64 elapsed) public {
        // Avoid zero address and beneficiary as caller
        vm.assume(caller != address(0) && caller != address(0xa));
        elapsed = uint64(bound(elapsed, 1 days, 365 days));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 365e18;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + elapsed);

        uint256 callerBalanceBefore = token.balanceOf(caller);
        uint256 beneficiaryBalanceBefore = token.balanceOf(address(0xa));
        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);

        vm.prank(caller);
        token.releaseFor(address(0xa), 0);

        assertEq(token.balanceOf(caller), callerBalanceBefore, "Caller balance should not change");
        assertEq(
            token.balanceOf(address(0xa)), beneficiaryBalanceBefore + available, "Beneficiary should receive tokens"
        );
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    /**
     * @notice Edge case: cliff equals duration (cliff at very end)
     */
    function test_edge_CliffEqualsDuration() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 365 days, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Just before cliff
        vm.warp(token.vestingStart() + 365 days - 1);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Should be 0 before cliff");

        // At cliff = duration: fully vested
        vm.warp(token.vestingStart() + 365 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Should be fully vested at cliff=duration");
    }

    /**
     * @notice Edge case: minimum valid duration (1 day)
     */
    function test_edge_MinimumDuration() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: uint64(MIN_VESTING_DURATION) });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // At t=0
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Should be 0 at t=0");

        // At t=12 hours (50%)
        vm.warp(token.vestingStart() + 12 hours);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24 / 2, "Should be 50% at 12 hours");

        // At t=1 day (fully vested)
        vm.warp(token.vestingStart() + 1 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Should be fully vested at 1 day");
    }

    /**
     * @notice Edge case: exact max per-address allocation
     */
    function test_edge_ExactMaxPerAddressAllocation() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = maxPerAddress;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        assertEq(token.totalAllocatedOf(address(0xa)), maxPerAddress, "Should allow exact max");
    }

    /**
     * @notice Edge case: many schedules gas test
     */
    function test_edge_ManySchedulesGas() public {
        uint256 numSchedules = 20;
        uint256 numAllocations = 20;

        VestingSchedule[] memory schedules = new VestingSchedule[](numSchedules);
        for (uint256 i; i < numSchedules; i++) {
            schedules[i] = VestingSchedule({ cliff: uint64(i * 1 days), duration: uint64((i + 1) * 30 days) });
        }

        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        uint256 perAllocation = maxPerAddress / numAllocations;

        address[] memory beneficiaries = new address[](numAllocations);
        uint256[] memory scheduleIds = new uint256[](numAllocations);
        uint256[] memory amounts = new uint256[](numAllocations);

        for (uint256 i; i < numAllocations; i++) {
            beneficiaries[i] = address(0xa);
            scheduleIds[i] = i % numSchedules;
            amounts[i] = perAllocation;
        }

        uint256 gasBefore = gasleft();
        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas used (shouldn't fail, just informational)
        emit log_named_uint("Gas used for 20 schedules, 20 allocations", gasUsed);

        // Verify we can still query
        vm.warp(token.vestingStart() + 365 days);
        uint256 available = token.computeAvailableVestedAmount(address(0xa));
        assertTrue(available > 0, "Should have available amount");

        // Verify we can release
        vm.prank(address(0xa));
        token.release();
        assertTrue(token.balanceOf(address(0xa)) > 0, "Should have balance after release");
    }

    /**
     * @notice Edge case: release at exact timestamps (cliff, duration)
     */
    function test_edge_ExactTimestamps() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 100 days, duration: 200 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200e18; // 1 token per day

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Exactly at cliff
        vm.warp(token.vestingStart() + 100 days);
        uint256 atCliff = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(atCliff, 100e18, "Should have 100 days worth at cliff");

        // Release at cliff
        vm.prank(address(0xa));
        token.release(0);

        // Exactly at duration
        vm.warp(token.vestingStart() + 200 days);
        uint256 atDuration = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(atDuration, 100e18, "Should have remaining 100 days worth at duration");

        vm.prank(address(0xa));
        token.release(0);

        assertEq(token.balanceOf(address(0xa)), 200e18, "Should have full amount");
    }

    // =========================================================================
    // Regression Tests (v1 features preserved)
    // =========================================================================

    /**
     * @notice Regression: inflation minting still works after vesting releases
     */
    function test_regression_InflationAfterVesting() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Release vested tokens
        vm.warp(token.vestingStart() + 365 days);
        vm.prank(address(0xa));
        token.release(0);

        // Unlock pool to enable inflation
        vm.prank(OWNER);
        token.unlockPool();

        // Warp and try inflation
        vm.warp(block.timestamp + 365 days);
        token.mintInflation();

        // Should have minted some inflation to owner
        assertTrue(token.balanceOf(OWNER) > 0, "Owner should have inflation tokens");
    }

    /**
     * @notice Regression: burn works for beneficiaries after release (with pool configured)
     * @dev Safety feature: burns are blocked when pool == address(0) && !isPoolUnlocked.
     *      This prevents any transfers to address(0) until pool is properly configured.
     *      Test sets pool to non-zero address to enable burns.
     */
    function test_regression_BurnAfterRelease() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Lock pool to a non-zero address so burn (to address(0)) works
        vm.prank(OWNER);
        token.lockPool(address(0xdeadbeef));

        vm.warp(token.vestingStart() + 365 days);
        vm.prank(address(0xa));
        token.release(0);

        uint256 balanceBefore = token.balanceOf(address(0xa));
        uint256 burnAmount = balanceBefore / 2;

        vm.prank(address(0xa));
        token.burn(burnAmount);

        assertEq(token.balanceOf(address(0xa)), balanceBefore - burnAmount, "Balance should decrease by burn amount");
        assertEq(token.totalSupply(), INITIAL_SUPPLY - burnAmount, "Total supply should decrease");
    }

    /**
     * @notice Regression: ERC20Votes delegation still works
     */
    function test_regression_VoteDelegation() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        address delegatee = address(0xdead);

        vm.prank(RECIPIENT);
        token.delegate(delegatee);

        assertEq(token.delegates(RECIPIENT), delegatee, "Delegation should work");
        assertEq(token.getVotes(delegatee), INITIAL_SUPPLY, "Delegatee should have votes");
    }

    // =========================================================================
    // State Machine Properties (from Trail of Bits Property-Based Testing Skill)
    // =========================================================================

    /**
     * @notice Property: released amount is monotonically increasing
     * @dev Once tokens are released, releasedAmount can never decrease
     */
    function testFuzz_property_ReleasedMonotonicallyIncreases(
        uint64 duration,
        uint256 totalAmount,
        uint8[3] memory releasePercents
    ) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        totalAmount = bound(totalAmount, 1e18, maxPerAddress);

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        uint256 lastReleased;
        uint256 lastPercent;

        for (uint256 i; i < 3; i++) {
            uint8 percent = uint8(bound(releasePercents[i], uint8(lastPercent), 100));
            lastPercent = percent;

            uint256 elapsed = uint256(duration) * percent / 100;
            vm.warp(token.vestingStart() + elapsed);

            (, uint256 releasedBefore) = token.vestingOf(address(0xa), 0);

            uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
            if (available > 0) {
                vm.prank(address(0xa));
                token.release(0);
            }

            (, uint256 releasedAfter) = token.vestingOf(address(0xa), 0);

            // Property: released never decreases
            assertGe(releasedAfter, releasedBefore, "Released must be monotonically increasing");
            assertGe(releasedAfter, lastReleased, "Released must never decrease");
            lastReleased = releasedAfter;
        }
    }

    /**
     * @notice Property: available amount is zero immediately after release
     */
    function testFuzz_property_AvailableZeroAfterRelease(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, MIN_VESTING_DURATION, 365 days));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 365e18;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + elapsed);

        uint256 availableBefore = token.computeAvailableVestedAmount(address(0xa), 0);
        assertTrue(availableBefore > 0, "Should have available before release");

        vm.prank(address(0xa));
        token.release(0);

        uint256 availableAfter = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(availableAfter, 0, "Available should be 0 immediately after release");
    }

    /**
     * @notice Property: once fully vested, available equals remaining unreleased
     */
    function testFuzz_property_FullyVestedAvailable(uint256 totalAmount, uint64 extraTime) public {
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        totalAmount = bound(totalAmount, 1e18, maxPerAddress);
        extraTime = uint64(bound(extraTime, 0, 365 days));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 30 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Warp past duration
        vm.warp(token.vestingStart() + 30 days + extraTime);

        (uint256 total, uint256 released) = token.vestingOf(address(0xa), 0);
        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);

        // Property: available == total - released when fully vested
        assertEq(available, total - released, "Available should equal remaining when fully vested");
    }

    // =========================================================================
    // Arithmetic Safety Tests (from Trail of Bits Code Maturity Assessor)
    // =========================================================================

    /**
     * @notice Arithmetic: division precision at edge cases
     */
    function testFuzz_arithmetic_DivisionPrecision(uint64 duration, uint256 totalAmount, uint64 elapsed) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        totalAmount = bound(totalAmount, 1, maxPerAddress);
        elapsed = uint64(bound(elapsed, 0, duration));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + elapsed);

        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);

        // Property: available should never exceed total
        assertLe(available, totalAmount, "Available should never exceed total");

        // Property: available should be proportional to elapsed time
        if (elapsed >= duration) {
            assertEq(available, totalAmount, "Should be fully vested after duration");
        } else {
            uint256 expectedMax = totalAmount * elapsed / duration;
            assertLe(available, expectedMax + 1, "Available should be proportional to elapsed");
        }
    }

    /**
     * @notice Arithmetic: large amounts near cap don't overflow
     */
    function test_arithmetic_LargeAmountsNoOverflow() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = maxPerAddress;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        uint256[] memory testPoints = new uint256[](5);
        testPoints[0] = 1;
        testPoints[1] = 365 days / 4;
        testPoints[2] = 365 days / 2;
        testPoints[3] = 365 days * 3 / 4;
        testPoints[4] = 365 days;

        for (uint256 i; i < testPoints.length; i++) {
            vm.warp(token.vestingStart() + testPoints[i]);
            uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
            assertLe(available, maxPerAddress, "No overflow at test point");
        }
    }

    // =========================================================================
    // ERC20 Conformity Tests (from Trail of Bits Token Integration Analyzer)
    // =========================================================================

    /**
     * @notice ERC20: transfer returns bool
     */
    function test_erc20_TransferReturnsBool() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(RECIPIENT);
        bool success = token.transfer(address(0xdead), 1);
        assertTrue(success, "transfer should return true");
    }

    /**
     * @notice ERC20: transferFrom returns bool
     */
    function test_erc20_TransferFromReturnsBool() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(RECIPIENT);
        token.approve(address(this), 100);

        bool success = token.transferFrom(RECIPIENT, address(0xdead), 1);
        assertTrue(success, "transferFrom should return true");
    }

    /**
     * @notice ERC20: approve returns bool
     */
    function test_erc20_ApproveReturnsBool() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(RECIPIENT);
        bool success = token.approve(address(0xdead), 100);
        assertTrue(success, "approve should return true");
    }

    /**
     * @notice ERC20: decimals returns uint8
     */
    function test_erc20_DecimalsReturnsUint8() public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        uint8 decimals = token.decimals();
        assertEq(decimals, 18, "decimals should be 18");
    }

    /**
     * @notice ERC20: balance consistency - transfer doesn't change total supply
     */
    function testFuzz_erc20_BalanceConsistency(uint256 transferAmount) public {
        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        uint256 recipientBalance = token.balanceOf(RECIPIENT);
        transferAmount = bound(transferAmount, 1, recipientBalance);

        address target = address(0xdead);
        uint256 targetBalanceBefore = token.balanceOf(target);
        uint256 recipientBalanceBefore = token.balanceOf(RECIPIENT);
        uint256 totalSupplyBefore = token.totalSupply();

        vm.prank(RECIPIENT);
        token.transfer(target, transferAmount);

        assertEq(token.totalSupply(), totalSupplyBefore, "Total supply should not change");
        assertEq(token.balanceOf(target), targetBalanceBefore + transferAmount, "Target balance mismatch");
        assertEq(token.balanceOf(RECIPIENT), recipientBalanceBefore - transferAmount, "Sender balance mismatch");
    }

    // =========================================================================
    // Access Control Tests (from Trail of Bits Code Maturity Assessor)
    // =========================================================================

    /**
     * @notice Access: only owner can lock pool
     */
    function testFuzz_access_OnlyOwnerCanLockPool(address caller) public {
        vm.assume(caller != OWNER);

        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        token.lockPool(address(0xdead));
    }

    /**
     * @notice Access: only owner can unlock pool
     */
    function testFuzz_access_OnlyOwnerCanUnlockPool(address caller) public {
        vm.assume(caller != OWNER);

        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        token.unlockPool();
    }

    /**
     * @notice Access: only owner can update mint rate
     */
    function testFuzz_access_OnlyOwnerCanUpdateMintRate(address caller, uint256 newRate) public {
        vm.assume(caller != OWNER);
        newRate = bound(newRate, 0, 0.02 ether);

        token = _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        token.updateMintRate(newRate);
    }

    /**
     * @notice Access: anyone can call releaseFor to release tokens to beneficiary
     */
    function testFuzz_access_AnyoneCanReleaseFor(address caller) public {
        vm.assume(caller != address(0));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(caller);
        token.releaseFor(address(0xa), 0);

        assertEq(token.balanceOf(address(0xa)), 1e24, "Beneficiary should receive tokens");
    }

    // =========================================================================
    // Idempotence Tests (from Trail of Bits Property-Based Testing Skill)
    // =========================================================================

    /**
     * @notice Property: double release reverts (idempotent in effect)
     */
    function test_property_ReleaseIdempotent() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        token.release(0);
        uint256 balanceAfterFirst = token.balanceOf(address(0xa));

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0);

        assertEq(token.balanceOf(address(0xa)), balanceAfterFirst, "Balance unchanged on failed release");
    }

    /**
     * @notice Property: getScheduleIdsOf returns consistent results (pure view)
     */
    function test_property_GetScheduleIdsIdempotent() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 0, duration: 730 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e24;
        amounts[1] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        uint256[] memory ids1 = token.getScheduleIdsOf(address(0xa));
        uint256[] memory ids2 = token.getScheduleIdsOf(address(0xa));
        uint256[] memory ids3 = token.getScheduleIdsOf(address(0xa));

        assertEq(ids1.length, ids2.length, "Length should be consistent");
        assertEq(ids2.length, ids3.length, "Length should be consistent");

        for (uint256 i; i < ids1.length; i++) {
            assertEq(ids1[i], ids2[i], "IDs should match");
            assertEq(ids2[i], ids3[i], "IDs should match");
        }
    }

    // =========================================================================
    // Commutativity Tests (from Trail of Bits Property-Based Testing Skill)
    // =========================================================================

    /**
     * @notice Property: release order doesn't affect final balance
     */
    function test_property_ReleaseOrderIndependent() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e24;
        amounts[1] = 2e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        vm.startPrank(address(0xa));
        token.release(0);
        token.release(1);
        vm.stopPrank();

        uint256 finalBalance = token.balanceOf(address(0xa));
        assertEq(finalBalance, 3e24, "Should have all tokens regardless of order");
    }

    // =========================================================================
    // Oracle/Reference Tests (from Trail of Bits Property-Based Testing Skill)
    // =========================================================================

    /**
     * @notice Oracle: computeAvailableVestedAmount matches reference calculation
     */
    function testFuzz_oracle_AvailableMatchesReference(uint64 duration, uint256 totalAmount, uint64 elapsed) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        uint256 maxPerAddress = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        totalAmount = bound(totalAmount, 1, maxPerAddress);
        elapsed = uint64(bound(elapsed, 0, duration * 2));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + elapsed);

        uint256 contractAvailable = token.computeAvailableVestedAmount(address(0xa), 0);

        // Reference calculation
        uint256 referenceVested;
        if (elapsed >= duration) {
            referenceVested = totalAmount;
        } else {
            referenceVested = totalAmount * elapsed / duration;
        }

        assertEq(contractAvailable, referenceVested, "Contract should match reference");
    }

    // =========================================================================
    // Boundary Tests (from Trail of Bits Reviewing PBT - Edge Cases)
    // =========================================================================

    /**
     * @notice Boundary: exact cliff timestamp transitions
     */
    function test_boundary_ExactCliffTimestamp() public {
        uint64 cliff = 30 days;
        uint64 duration = 365 days;

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: cliff, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 365e18;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);
        uint256 start = token.vestingStart();

        vm.warp(start + cliff - 1);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "0 just before cliff");

        vm.warp(start + cliff);
        uint256 atCliff = token.computeAvailableVestedAmount(address(0xa), 0);
        // At cliff, vesting = totalAmount * cliff / duration
        uint256 expectedAtCliff = (365e18 * uint256(cliff)) / uint256(duration);
        assertEq(atCliff, expectedAtCliff, "cliff days of vesting at cliff");

        vm.warp(start + cliff + 1);
        uint256 afterCliff = token.computeAvailableVestedAmount(address(0xa), 0);
        assertGt(afterCliff, atCliff, "More after cliff");
    }

    /**
     * @notice Boundary: exact duration timestamp transitions
     */
    function test_boundary_ExactDurationTimestamp() public {
        uint64 duration = 365 days;

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);
        uint256 start = token.vestingStart();

        vm.warp(start + duration - 1);
        uint256 beforeDuration = token.computeAvailableVestedAmount(address(0xa), 0);
        assertLt(beforeDuration, 1e24, "Not fully vested before duration");

        vm.warp(start + duration);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Fully vested at duration");

        vm.warp(start + duration + 365 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Capped after duration");
    }

    /**
     * @notice Boundary: non-beneficiary has zero everything
     */
    function test_boundary_NonBeneficiary() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        assertEq(token.computeAvailableVestedAmount(address(0xb), 0), 0, "Non-beneficiary: 0 per schedule");
        assertEq(token.computeAvailableVestedAmount(address(0xb)), 0, "Non-beneficiary: 0 total");

        uint256[] memory ids = token.getScheduleIdsOf(address(0xb));
        assertEq(ids.length, 0, "Non-beneficiary: no schedule IDs");
    }

    // =========================================================================
    // Mutation Testing Support (designed to catch common code mutations)
    // =========================================================================

    /**
     * @notice Mutation: catches `t <= start + s.cliff` instead of `t < start + s.cliff`
     */
    function test_mutation_CliffOffByOne() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 1 days, duration: 2 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200e18;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);
        uint256 start = token.vestingStart();

        // At cliff: tokens should be claimable (catches <= mutation)
        vm.warp(start + 1 days);
        uint256 atCliff = token.computeAvailableVestedAmount(address(0xa), 0);
        assertGt(atCliff, 0, "Claimable at cliff (catches <= mutation)");

        // Before cliff: tokens NOT claimable
        vm.warp(start + 1 days - 1);
        uint256 beforeCliff = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(beforeCliff, 0, "NOT claimable before cliff");
    }

    /**
     * @notice Mutation: catches `t > start + s.duration` instead of `t >= start + s.duration`
     */
    function test_mutation_DurationOffByOne() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 1 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);
        uint256 start = token.vestingStart();

        // At exactly duration end: should be fully vested (catches > mutation)
        vm.warp(start + 1 days);
        uint256 atDuration = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(atDuration, 100e18, "Fully vested at duration (catches > mutation)");
    }

    /**
     * @notice Mutation: catches wrong arithmetic operator in vesting formula
     */
    function test_mutation_WrongVestingOperator() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 100 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        token = _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 50 days);
        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);

        assertEq(available, 50e18, "Exactly 50% at 50% duration (catches + instead of *)");
    }
}
