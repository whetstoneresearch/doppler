// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Ownable } from "@solady/auth/Ownable.sol";
import { Initializable } from "@solady/utils/Initializable.sol";
import { Test } from "forge-std/Test.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import {
    ArrayLengthsMismatch,
    BalanceLimitDisabled,
    BalanceLimitExceeded,
    BalanceLimitNotActive,
    DopplerERC20V1,
    InsufficientReleasableAmount,
    InvalidAllocation,
    InvalidBalanceLimit,
    InvalidBalanceLimitTimestamp,
    InvalidSchedule,
    MAX_PRE_MINT_PER_ADDRESS_WAD,
    MAX_TOTAL_PRE_MINT_WAD,
    MAX_YEARLY_MINT_RATE_WAD,
    MIN_VESTING_DURATION,
    MaxPreMintPerAddressExceeded,
    MaxTotalPreMintExceeded,
    MaxYearlyMintRateExceeded,
    MintingNotStartedYet,
    NoMintableAmount,
    NoReleasableAmount,
    PoolLocked,
    UnknownScheduleId,
    UpdateMintRate,
    UpdateTokenURI,
    VestingSchedule
} from "src/tokens/DopplerERC20V1.sol";

uint256 constant INITIAL_SUPPLY = 1e26;
uint256 constant YEARLY_MINT_RATE = 0.02e18;
uint256 constant DEFAULT_MAX_BALANCE_LIMIT = 5e23;
string constant NAME = "TestV1";
string constant SYMBOL = "TSTV1";
string constant TOKEN_URI = "ipfs://QmInitialURI";
address constant RECIPIENT = address(0xa71ce);
address constant OWNER = address(0xb0b);
address constant CONTROLLER = address(0xc0ffee);

contract DopplerERC20V1Test is Test {
    DopplerERC20V1 public token;
    DopplerERC20V1 internal implementation;

    function setUp() public {
        implementation = new DopplerERC20V1();
        token = DopplerERC20V1(LibClone.clone(address(implementation)));
    }

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

    function _defaultLimitEnd() internal view returns (uint48) {
        return uint48(block.timestamp + 7 days);
    }

    function _maxPerAddress() internal pure returns (uint256) {
        return INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
    }

    function _createSingleScheduleToken(address beneficiary, uint256 amount, uint64 cliff, uint64 duration) internal {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: cliff, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = beneficiary;

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function _createSingleScheduleTokenWithBalanceLimit(
        address beneficiary,
        uint256 amount,
        uint64 cliff,
        uint64 duration,
        uint256 maxBalanceLimit,
        uint48 balanceLimitEnd,
        address controller,
        address[] memory excludedFromBalanceLimit
    ) internal {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: cliff, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = beneficiary;

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        _createToken(
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            maxBalanceLimit,
            balanceLimitEnd,
            controller,
            excludedFromBalanceLimit
        );
    }

    function _createToken(
        VestingSchedule[] memory schedules,
        address[] memory beneficiaries,
        uint256[] memory scheduleIds,
        uint256[] memory amounts
    ) internal {
        _createToken(schedules, beneficiaries, scheduleIds, amounts, 0, 0, address(0), _emptyAddresses());
    }

    function _createToken(
        VestingSchedule[] memory schedules,
        address[] memory beneficiaries,
        uint256[] memory scheduleIds,
        uint256[] memory amounts,
        uint256 maxBalanceLimit,
        uint48 balanceLimitEnd,
        address controller,
        address[] memory excludedFromBalanceLimit
    ) internal {
        token.initialize(
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
            TOKEN_URI,
            maxBalanceLimit,
            balanceLimitEnd,
            controller,
            excludedFromBalanceLimit
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                                initialize()                                */
    /* -------------------------------------------------------------------------- */

    function test_initialize_BasicSetup() public {
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

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        // Basic assertions
        assertEq(token.name(), NAME, "Wrong name");
        assertEq(token.symbol(), SYMBOL, "Wrong symbol");
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "Wrong total supply");
        assertEq(token.vestingStart(), block.timestamp, "Wrong vesting start");
        assertEq(token.vestedTotalAmount(), 4e24, "Wrong vested total");
        assertEq(token.owner(), OWNER, "Wrong owner");
        assertEq(token.yearlyMintRate(), YEARLY_MINT_RATE, "Wrong yearly mint rate");
        assertEq(token.tokenURI(), TOKEN_URI, "Wrong token URI");

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

    function test_initialize_NoVesting() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        assertEq(token.vestedTotalAmount(), 0, "Should have no vested amount");
        assertEq(token.balanceOf(RECIPIENT), INITIAL_SUPPLY, "Recipient should get all");
        assertEq(token.balanceOf(address(token)), 0, "Contract should have nothing");
        assertEq(token.vestingScheduleCount(), 0, "Should have no schedules");
    }

    function test_initialize_AggregatesDuplicateAllocations() public {
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

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        (uint256 total,) = token.vestingOf(address(0xa), 0);
        assertEq(total, 3e24, "Allocations should be aggregated");

        uint256[] memory ids = token.getScheduleIdsOf(address(0xa));
        assertEq(ids.length, 1, "Should only have one schedule ID entry");
        assertEq(token.totalAllocatedOf(address(0xa)), 3e24, "Wrong total allocated for beneficiary");
    }

    function test_initialize_DurationZeroIsInstantVest() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 0);

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Should be fully vested at t=0");

        vm.prank(address(0xa));
        token.release(0, 0);
        assertEq(token.balanceOf(address(0xa)), 1e24, "Should receive full amount");
    }

    function test_initialize_BalanceLimitDefaultsExcludeVestedUsers() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        _createToken(
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        assertTrue(token.isBalanceLimitActive(), "Balance limit should be active");
        assertTrue(token.isExcludedFromBalanceLimit(OWNER), "Owner should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(RECIPIENT), "Recipient should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(0xa)), "Beneficiary should be excluded by default");
    }

    function test_initialize_RevertsWhenArrayLengthsMismatch() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](2);
        uint256[] memory scheduleIds = new uint256[](1);
        uint256[] memory amounts = new uint256[](2);

        vm.expectRevert(ArrayLengthsMismatch.selector);
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_initialize_RevertsWhenInvalidScheduleCliffGreaterThanDuration() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 2 days, duration: 1 days });

        vm.expectRevert(abi.encodeWithSelector(InvalidSchedule.selector, 0));
        _createToken(schedules, _emptyAddresses(), _emptyUints(), _emptyUints());
    }

    function test_initialize_RevertsWhenDurationBelowMinimum() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: uint64(MIN_VESTING_DURATION - 1) });

        vm.expectRevert(abi.encodeWithSelector(InvalidSchedule.selector, 0));
        _createToken(schedules, _emptyAddresses(), _emptyUints(), _emptyUints());
    }

    function test_initialize_RevertsWhenUnknownScheduleId() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        vm.expectRevert(abi.encodeWithSelector(UnknownScheduleId.selector, 1));
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_initialize_RevertsWhenInvalidAllocationZeroAddress() public {
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

    function test_initialize_RevertsWhenInvalidAllocationZeroAmount() public {
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

    function test_initialize_RevertsWhenMaxPreMintPerAddressExceeded() public {
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

    function test_initialize_RevertsWhenMaxPreMintPerAddressExceededAcrossSchedules() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 0, duration: 730 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256 maxPerAddress = _maxPerAddress();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = maxPerAddress;
        amounts[1] = 1;

        vm.expectRevert(abi.encodeWithSelector(MaxPreMintPerAddressExceeded.selector, maxPerAddress + 1, maxPerAddress));
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
    }

    function test_initialize_RevertsWhenMaxTotalPreMintExceeded() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

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

    function test_initialize_RevertsWhenYearlyMintRateExceedsMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxYearlyMintRateExceeded.selector, MAX_YEARLY_MINT_RATE_WAD + 1, MAX_YEARLY_MINT_RATE_WAD
            )
        );
        token.initialize(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            OWNER,
            MAX_YEARLY_MINT_RATE_WAD + 1,
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            TOKEN_URI,
            0,
            0,
            address(0),
            new address[](0)
        );
    }

    function test_initialize_RevertsWhenInvalidBalanceLimit() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidBalanceLimit.selector, 0));
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            0,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );
    }

    function test_initialize_RevertsWhenBalanceLimitEqualsInitialSupply() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidBalanceLimit.selector, INITIAL_SUPPLY));
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            INITIAL_SUPPLY,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );
    }

    function test_initialize_RevertsWhenBalanceLimitGreaterThanInitialSupply() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidBalanceLimit.selector, INITIAL_SUPPLY + 1));
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            INITIAL_SUPPLY + 1,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );
    }

    function test_initialize_RevertsWhenBalanceLimitEndMissingButLimitSet() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidBalanceLimitTimestamp.selector, 0, block.timestamp));
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            0,
            CONTROLLER,
            _emptyAddresses()
        );
    }

    function test_initialize_RevertsWhenInvalidBalanceLimitTimestamp() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidBalanceLimitTimestamp.selector, block.timestamp, block.timestamp));
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            uint48(block.timestamp),
            CONTROLLER,
            _emptyAddresses()
        );
    }

    function test_initialize_RevertsWhenAlreadyInitialized() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());
    }

    /* ---------------------------------------------------------------------------- */
    /*                                updateTokenURI                                */
    /* ---------------------------------------------------------------------------- */

    function test_updateTokenURI() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());
        string memory newURI = "ipfs://QmTest123";

        vm.expectEmit();
        emit UpdateTokenURI(newURI);
        vm.prank(OWNER);
        token.updateTokenURI(newURI);
        assertEq(token.tokenURI(), newURI, "Token URI should be updated");
    }

    function test_updateTokenURI_RevertsWhenNotOwner() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.updateTokenURI("ipfs://QmTest");
    }

    /* ---------------------------------------------------------------------------- */
    /*                                   release                                    */
    /* ---------------------------------------------------------------------------- */

    function test_release_PartialSingleSchedule() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        token.release(0, 4e23);

        assertEq(token.balanceOf(address(0xa)), 4e23, "Wrong partial balance");
        (, uint256 released) = token.vestingOf(address(0xa), 0);
        assertEq(released, 4e23, "Wrong released amount");
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 6e23, "Wrong remaining amount");
    }

    function test_release_PartialSingleScheduleRevertsWhenRequestExceedsAvailable() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + 365 days / 2);

        vm.prank(address(0xa));
        vm.expectRevert(abi.encodeWithSelector(InsufficientReleasableAmount.selector, 5e23, 5e23 + 1));
        token.release(0, 5e23 + 1);
    }

    function test_releaseFor_PartialSingleSchedule() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xdead));
        token.releaseFor(address(0xa), 0, 3e23);

        assertEq(token.balanceOf(address(0xa)), 3e23, "Tokens should go to beneficiary");
        (, uint256 released) = token.vestingOf(address(0xa), 0);
        assertEq(released, 3e23, "Wrong released amount");
    }

    function test_release_PartialAcrossSchedules() public {
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
        amounts[0] = 30;
        amounts[1] = 30;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        token.release(35);

        assertEq(token.balanceOf(address(0xa)), 35, "Wrong released total");
        (, uint256 released0) = token.vestingOf(address(0xa), 0);
        (, uint256 released1) = token.vestingOf(address(0xa), 1);
        assertEq(released0, 30, "Wrong first schedule released amount");
        assertEq(released1, 5, "Wrong second schedule released amount");
    }

    function test_release_PartialAcrossSchedulesSkipsUnavailableSchedule() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 2 days, duration: 2 days });
        schedules[1] = VestingSchedule({ cliff: 0, duration: 1 days });

        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(0xa);
        beneficiaries[1] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 100e18;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 1 days);

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Schedule 0 should still be cliff-blocked");
        assertEq(token.computeAvailableVestedAmount(address(0xa), 1), 100e18, "Schedule 1 should be fully available");

        vm.prank(address(0xa));
        token.release(60e18);

        assertEq(token.balanceOf(address(0xa)), 60e18, "Wrong released total");

        (, uint256 released0) = token.vestingOf(address(0xa), 0);
        (, uint256 released1) = token.vestingOf(address(0xa), 1);

        assertEq(released0, 0, "Unavailable schedule should not be released");
        assertEq(released1, 60e18, "Available schedule should satisfy the partial release");
        assertEq(token.computeAvailableVestedAmount(address(0xa), 1), 40e18, "Wrong remaining amount on schedule 1");
    }

    function test_releaseFor_PartialAcrossSchedules() public {
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
        amounts[0] = 30;
        amounts[1] = 30;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xdead));
        token.releaseFor(address(0xa), 35);

        assertEq(token.balanceOf(address(0xa)), 35, "Wrong beneficiary released total");
        (, uint256 released0) = token.vestingOf(address(0xa), 0);
        (, uint256 released1) = token.vestingOf(address(0xa), 1);
        assertEq(released0, 30, "Wrong first schedule released amount");
        assertEq(released1, 5, "Wrong second schedule released amount");
    }

    function test_release_RevertsWhenPartialAcrossSchedulesExceedsAvailable() public {
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
        amounts[0] = 30;
        amounts[1] = 30;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        vm.expectRevert(abi.encodeWithSelector(InsufficientReleasableAmount.selector, 60, 61));
        token.release(61);
    }

    function test_release_ZeroAmountMeansReleaseAllAcrossSchedules() public {
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

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        token.release(0);

        assertEq(token.balanceOf(address(0xa)), 3e24, "Should release all available schedules");
    }

    function test_release_RevertsWhenNoReleasableAmount() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 365 days, duration: 730 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0, 0);
    }

    function test_releaseFor_AnyoneCanCall() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xdead));
        token.releaseFor(address(0xa), 0, 0);

        assertEq(token.balanceOf(address(0xa)), 1e24, "Tokens should go to beneficiary");
    }

    function test_release_RevertsWhenUnknownScheduleId() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.prank(address(0xa));
        vm.expectRevert(abi.encodeWithSelector(UnknownScheduleId.selector, 1));
        token.release(1, 0);
    }

    function test_releaseFor_RevertsWhenUnknownScheduleId() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.expectRevert(abi.encodeWithSelector(UnknownScheduleId.selector, 1));
        token.releaseFor(address(0xa), 1, 0);
    }

    // =========================================================================
    // Pool Lock Tests
    // =========================================================================

    function test_poolLock_TransferBlocked() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(OWNER);
        token.lockPool(address(0xdeadbeef));

        vm.prank(RECIPIENT);
        vm.expectRevert(PoolLocked.selector);
        token.transfer(address(0xdeadbeef), 1);
    }

    function test_poolLock_UnlockAllowsTransfer() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.startPrank(OWNER);
        token.lockPool(address(0xdeadbeef));
        token.unlockPool();
        vm.stopPrank();

        vm.prank(RECIPIENT);
        token.transfer(address(0xdeadbeef), 1);
        assertEq(token.balanceOf(address(0xdeadbeef)), 1, "Transfer should succeed after unlock");
    }

    // =========================================================================
    // Balance Limit Tests
    // =========================================================================

    function test_balanceLimit_BlocksTransferToNonExcludedAddress() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.prank(RECIPIENT);
        vm.expectRevert(
            abi.encodeWithSelector(
                BalanceLimitExceeded.selector, DEFAULT_MAX_BALANCE_LIMIT + 1, DEFAULT_MAX_BALANCE_LIMIT
            )
        );
        token.transfer(address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT + 1);
    }

    function test_balanceLimit_AllowsTransferUpToLimit() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.prank(RECIPIENT);
        token.transfer(address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT);

        assertEq(token.balanceOf(address(0xbeef)), DEFAULT_MAX_BALANCE_LIMIT, "Should allow transfer at limit");
        assertTrue(token.isBalanceLimitActive(), "Balance limit should stay active");
    }

    function test_balanceLimit_BlocksTransferWhenSecondTransferCrossesLimit() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.startPrank(RECIPIENT);
        token.transfer(address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT);

        vm.expectRevert(
            abi.encodeWithSelector(
                BalanceLimitExceeded.selector, DEFAULT_MAX_BALANCE_LIMIT + 1, DEFAULT_MAX_BALANCE_LIMIT
            )
        );
        token.transfer(address(0xbeef), 1);
        vm.stopPrank();
    }

    function test_balanceLimit_AllowsTransferToExplicitlyExcludedAddress() public {
        address[] memory excluded = new address[](1);
        excluded[0] = address(0xbeef);

        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            excluded
        );

        vm.prank(RECIPIENT);
        token.transfer(address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT + 1);

        assertTrue(token.isExcludedFromBalanceLimit(address(0xbeef)), "Excluded address should remain excluded");
        assertEq(
            token.balanceOf(address(0xbeef)), DEFAULT_MAX_BALANCE_LIMIT + 1, "Excluded address should receive tokens"
        );
    }

    function test_balanceLimit_ControllerCanDisable() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.expectEmit();
        emit BalanceLimitDisabled(false);
        vm.prank(CONTROLLER);
        token.disableBalanceLimit();
        assertFalse(token.isBalanceLimitActive(), "Balance limit should be disabled");
    }

    function test_balanceLimit_RevertsWhenControllerDisablesTwice() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.prank(CONTROLLER);
        token.disableBalanceLimit();

        vm.prank(CONTROLLER);
        vm.expectRevert(BalanceLimitNotActive.selector);
        token.disableBalanceLimit();
    }

    function test_balanceLimit_ControllerDisableAllowsOverLimitTransfer() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.prank(CONTROLLER);
        token.disableBalanceLimit();

        vm.prank(RECIPIENT);
        token.transfer(address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT + 1);

        assertFalse(token.isBalanceLimitActive(), "Balance limit should stay disabled");
        assertEq(
            token.balanceOf(address(0xbeef)),
            DEFAULT_MAX_BALANCE_LIMIT + 1,
            "Disabled balance limit should allow over-cap transfer"
        );
    }

    function test_balanceLimit_TransferFromBlocksTransferToNonExcludedAddress() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        address spender = address(0x1234);
        vm.prank(RECIPIENT);
        token.approve(spender, DEFAULT_MAX_BALANCE_LIMIT + 1);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(
                BalanceLimitExceeded.selector, DEFAULT_MAX_BALANCE_LIMIT + 1, DEFAULT_MAX_BALANCE_LIMIT
            )
        );
        token.transferFrom(RECIPIENT, address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT + 1);
    }

    function test_balanceLimit_TransferFromAllowsTransferUpToLimit() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        address spender = address(0x1234);
        vm.prank(RECIPIENT);
        token.approve(spender, DEFAULT_MAX_BALANCE_LIMIT);

        vm.prank(spender);
        token.transferFrom(RECIPIENT, address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT);

        assertEq(token.balanceOf(address(0xbeef)), DEFAULT_MAX_BALANCE_LIMIT, "Wrong transferFrom balance");
    }

    function test_balanceLimit_RevertsWhenNonControllerDisables() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.expectRevert(Ownable.Unauthorized.selector);
        token.disableBalanceLimit();
    }

    function test_balanceLimit_PoolExcludedWhenLocked() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        address poolAddr = address(0xdeadbeef);
        vm.prank(OWNER);
        token.lockPool(poolAddr);

        assertTrue(token.isExcludedFromBalanceLimit(poolAddr), "Pool should be excluded from balance limit");
    }

    function test_balanceLimit_ExpiresOnTransfer() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.warp(_defaultLimitEnd() + 1);
        vm.prank(RECIPIENT);
        token.transfer(address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT + 1);
        assertFalse(token.isBalanceLimitActive(), "Balance limit should auto-disable");
    }

    function test_balanceLimit_ExpiresAtExactEndTimestamp() public {
        uint48 limitEnd = uint48(block.timestamp + 7 days);

        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            limitEnd,
            CONTROLLER,
            _emptyAddresses()
        );

        vm.warp(limitEnd);

        vm.expectEmit();
        emit BalanceLimitDisabled(true);
        vm.prank(RECIPIENT);
        token.transfer(address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT + 1);

        assertFalse(token.isBalanceLimitActive(), "Balance limit should disable at exact end timestamp");
        assertEq(
            token.balanceOf(address(0xbeef)),
            DEFAULT_MAX_BALANCE_LIMIT + 1,
            "Transfer at exact expiry should bypass cap"
        );
    }

    function test_balanceLimit_ExcludedTransferAfterExpiryDoesNotLazyDisable() public {
        address[] memory excluded = new address[](1);
        excluded[0] = address(0xbeef);
        uint48 limitEnd = uint48(block.timestamp + 7 days);

        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            limitEnd,
            CONTROLLER,
            excluded
        );

        vm.warp(limitEnd);

        vm.prank(RECIPIENT);
        token.transfer(address(0xbeef), DEFAULT_MAX_BALANCE_LIMIT + 1);

        vm.prank(RECIPIENT);
        token.transfer(address(0xcafe), DEFAULT_MAX_BALANCE_LIMIT + 1);

        assertFalse(token.isBalanceLimitActive(), "Non-excluded transfer should lazy-disable");
    }

    function test_balanceLimit_TransferOwnershipExcludesNewOwner() public {
        address newOwner = address(0xfeed);

        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        assertFalse(token.isExcludedFromBalanceLimit(newOwner), "New owner should start non-excluded");

        vm.prank(OWNER);
        token.transferOwnership(newOwner);

        assertEq(token.owner(), newOwner, "Ownership should transfer");
        assertTrue(token.isExcludedFromBalanceLimit(newOwner), "New owner should be excluded from balance limit");
    }

    function test_balanceLimit_UnlockedPoolCanReceiveAboveCap() public {
        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        address poolAddr = address(0xdeadbeef);

        vm.startPrank(OWNER);
        token.lockPool(poolAddr);
        token.unlockPool();
        vm.stopPrank();

        vm.prank(RECIPIENT);
        token.transfer(poolAddr, DEFAULT_MAX_BALANCE_LIMIT + 1);

        assertTrue(token.isExcludedFromBalanceLimit(poolAddr), "Pool should be excluded");
        assertEq(
            token.balanceOf(poolAddr),
            DEFAULT_MAX_BALANCE_LIMIT + 1,
            "Unlocked excluded pool should receive over-cap transfer"
        );
    }

    // =========================================================================
    // Mint Tests
    // =========================================================================

    function test_mintInflation_RevertsBeforeUnlock() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(MintingNotStartedYet.selector);
        token.mintInflation();
    }

    function test_mintInflation_OwnerReceivesTokens() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());
        vm.prank(OWNER);
        token.unlockPool();
        vm.warp(block.timestamp + 365 days);

        uint256 ownerBalanceBefore = token.balanceOf(OWNER);
        token.mintInflation();
        assertGt(token.balanceOf(OWNER), ownerBalanceBefore, "Owner should receive minted tokens");
    }

    function test_mintInflation_NewOwnerReceivesTokensAfterTransferOwnershipWhileCapActive() public {
        address newOwner = address(0xfeed);

        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.prank(RECIPIENT);
        token.transfer(newOwner, DEFAULT_MAX_BALANCE_LIMIT);

        vm.prank(OWNER);
        token.transferOwnership(newOwner);

        vm.prank(newOwner);
        token.unlockPool();

        vm.warp(block.timestamp + 365 days);

        uint256 ownerBalanceBefore = token.balanceOf(newOwner);
        vm.prank(newOwner);
        token.mintInflation();

        assertGt(token.balanceOf(newOwner), ownerBalanceBefore, "New owner should receive minted inflation");
        assertGt(token.balanceOf(newOwner), DEFAULT_MAX_BALANCE_LIMIT, "New owner mint should bypass active cap");
    }

    function test_mintInflation_ExactOneYearAmount() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(OWNER);
        token.unlockPool();

        vm.warp(block.timestamp + 365 days);
        token.mintInflation();

        uint256 expectedMint = INITIAL_SUPPLY * YEARLY_MINT_RATE / 1e18;
        assertEq(token.balanceOf(OWNER), expectedMint, "Wrong one-year mint amount");
    }

    function test_mintInflation_ExactMultipleYearsCompounds() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(OWNER);
        token.unlockPool();

        uint256 supply = INITIAL_SUPPLY;
        uint256 expectedMint;
        for (uint256 i; i < 3; i++) {
            uint256 yearMint = supply * YEARLY_MINT_RATE / 1e18;
            expectedMint += yearMint;
            supply += yearMint;
        }

        vm.warp(block.timestamp + 3 * 365 days);
        token.mintInflation();

        assertEq(token.balanceOf(OWNER), expectedMint, "Wrong compounded mint amount");
        assertEq(token.totalSupply(), INITIAL_SUPPLY + expectedMint, "Wrong compounded total supply");
    }

    function test_updateMintRate_RevertsWhenNotOwner() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.updateMintRate(0.01 ether);
    }

    function test_updateMintRate_NewRateApplies() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());
        uint256 newRate = 0.01 ether;

        vm.expectEmit();
        emit UpdateMintRate(newRate);
        vm.prank(OWNER);
        token.updateMintRate(newRate);
        assertEq(token.yearlyMintRate(), newRate, "Mint rate should be updated");
    }

    function test_updateMintRate_MintsElapsedTimeAtOldRate() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(OWNER);
        token.unlockPool();

        uint256 elapsed = 180 days;
        uint256 newRate = 0.01 ether;
        uint256 expectedMint = INITIAL_SUPPLY * YEARLY_MINT_RATE * elapsed / (1e18 * 365 days);

        vm.warp(block.timestamp + elapsed);

        vm.prank(OWNER);
        token.updateMintRate(newRate);

        assertEq(token.balanceOf(OWNER), expectedMint, "Should mint elapsed amount at old rate");
        assertEq(token.yearlyMintRate(), newRate, "Mint rate should be updated");
        assertEq(token.lastMintTimestamp(), block.timestamp, "Mint timestamp should advance");
    }

    function test_updateMintRate_NewOwnerCanMintElapsedAmountAfterTransferOwnershipWhileCapActive() public {
        address newOwner = address(0xfeed);
        uint256 newRate = 0.01 ether;

        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.prank(RECIPIENT);
        token.transfer(newOwner, DEFAULT_MAX_BALANCE_LIMIT);

        vm.prank(OWNER);
        token.transferOwnership(newOwner);

        vm.prank(newOwner);
        token.unlockPool();

        vm.warp(block.timestamp + 180 days);

        uint256 ownerBalanceBefore = token.balanceOf(newOwner);
        vm.prank(newOwner);
        token.updateMintRate(newRate);

        assertGt(token.balanceOf(newOwner), ownerBalanceBefore, "New owner should receive accrued mint amount");
        assertGt(token.balanceOf(newOwner), DEFAULT_MAX_BALANCE_LIMIT, "Accrued mint should bypass active cap");
        assertEq(token.yearlyMintRate(), newRate, "Mint rate should update for transferred owner");
        assertEq(token.lastMintTimestamp(), block.timestamp, "Mint timestamp should advance");
    }

    // =========================================================================
    // Votes Tests
    // =========================================================================

    function test_votingPower_CountsAfterRelease() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e24;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.prank(address(0xa));
        token.delegate(address(0xa));
        assertEq(token.getVotes(address(0xa)), 0, "Unreleased tokens should not vote");

        vm.warp(token.vestingStart() + 365 days);
        vm.prank(address(0xa));
        token.release(0, 0);
        assertEq(token.getVotes(address(0xa)), 1e24, "Released tokens should count for votes");
    }

    // =========================================================================
    // Fuzz Tests - Vesting Math
    // =========================================================================

    function testFuzz_linearVesting_AtAnyPoint(uint64 duration, uint256 totalAmount, uint8 elapsedPercent) public {
        duration = uint64(bound(duration, 1 days, 10 * 365 days));
        totalAmount = bound(totalAmount, 1, INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18);
        elapsedPercent = uint8(bound(elapsedPercent, 0, 100));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: duration });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        uint256 elapsed = uint256(duration) * elapsedPercent / 100;
        vm.warp(token.vestingStart() + elapsed);

        uint256 expected = elapsed >= duration ? totalAmount : totalAmount * elapsed / duration;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected, "Vested amount mismatch");
    }

    function testFuzz_partialRelease_NeverExceedsRequested(
        uint64 duration,
        uint256 totalAmount,
        uint8 elapsedPercent,
        uint256 requestedSeed
    ) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        totalAmount = bound(totalAmount, 2, _maxPerAddress());
        elapsedPercent = uint8(bound(elapsedPercent, 1, 100));

        _createSingleScheduleToken(address(0xa), totalAmount, 0, duration);

        uint256 elapsed = uint256(duration) * elapsedPercent / 100;
        vm.warp(token.vestingStart() + elapsed);

        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
        vm.assume(available > 0);

        uint256 requested = bound(requestedSeed, 1, available);

        vm.prank(address(0xa));
        token.release(0, requested);

        assertEq(token.balanceOf(address(0xa)), requested, "Should release exactly requested amount");

        (, uint256 released) = token.vestingOf(address(0xa), 0);
        assertEq(released, requested, "Stored released amount should equal requested amount");
        assertEq(
            token.computeAvailableVestedAmount(address(0xa), 0),
            available - requested,
            "Remaining available amount should decrease by requested amount"
        );
    }

    function testFuzz_releaseFor_TokensAlwaysGoBeneficiary(address caller, uint64 elapsed) public {
        vm.assume(caller != address(0));
        vm.assume(caller != address(0xa));
        vm.assume(caller != address(token));
        elapsed = uint64(bound(elapsed, 1 days, 365 days));

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xa);

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 365e18;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        vm.warp(token.vestingStart() + elapsed);

        uint256 callerBalanceBefore = token.balanceOf(caller);
        uint256 beneficiaryBalanceBefore = token.balanceOf(address(0xa));
        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);

        vm.prank(caller);
        token.releaseFor(address(0xa), 0, 0);

        assertEq(token.balanceOf(caller), callerBalanceBefore, "Caller balance should not change");
        assertEq(
            token.balanceOf(address(0xa)),
            beneficiaryBalanceBefore + available,
            "Beneficiary should receive released tokens"
        );
    }

    function test_partialRelease_SameTimestampLeavesRemainderAndLaterVestsMore() public {
        _createSingleScheduleToken(address(0xa), 1000e18, 0, 100 days);

        vm.warp(token.vestingStart() + 50 days);

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 500e18, "Wrong initial half-way availability");

        vm.prank(address(0xa));
        token.release(0, 200e18);

        assertEq(token.balanceOf(address(0xa)), 200e18, "Wrong partial balance");

        (, uint256 releasedAfterPartial) = token.vestingOf(address(0xa), 0);
        assertEq(releasedAfterPartial, 200e18, "Wrong released after partial claim");
        assertEq(
            token.computeAvailableVestedAmount(address(0xa), 0),
            300e18,
            "Same timestamp should retain unclaimed available remainder"
        );

        vm.warp(token.vestingStart() + 100 days);

        assertEq(
            token.computeAvailableVestedAmount(address(0xa), 0),
            800e18,
            "At full vesting, available should equal total minus partial release"
        );

        vm.prank(address(0xa));
        token.release(0, 0);

        assertEq(token.balanceOf(address(0xa)), 1000e18, "Should eventually receive full amount");

        (, uint256 finalReleased) = token.vestingOf(address(0xa), 0);
        assertEq(finalReleased, 1000e18, "Released amount should equal total amount");
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Nothing should remain available");
    }

    // =========================================================================
    // Cliff Gating Tests
    // =========================================================================

    function test_cliffGating_NothingClaimableBeforeCliff() public {
        _createSingleScheduleToken(address(0xa), 1e24, 180 days, 365 days);

        vm.warp(token.vestingStart() + 180 days - 1);

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Should be 0 before cliff");
        assertEq(token.computeAvailableVestedAmount(address(0xa)), 0, "Total should be 0 before cliff");

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0, 0);
    }

    function test_cliffGating_ClaimableAtCliff() public {
        _createSingleScheduleToken(address(0xa), 365e18, 180 days, 365 days);

        vm.warp(token.vestingStart() + 180 days);

        uint256 expected = 365e18 * 180 days / 365 days;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected, "Wrong available at cliff");

        vm.prank(address(0xa));
        token.release(0, 0);
        assertEq(token.balanceOf(address(0xa)), expected, "Wrong balance after release");
    }

    function test_cliffGating_ZeroCliffWorksImmediately() public {
        _createSingleScheduleToken(address(0xa), 365e18, 0, 365 days);

        vm.warp(token.vestingStart() + 1 days);

        uint256 expected = 365e18 * 1 days / 365 days;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected, "Wrong available with zero cliff");
    }

    function test_edge_CliffEqualsDuration() public {
        _createSingleScheduleToken(address(0xa), 1e24, 365 days, 365 days);

        vm.warp(token.vestingStart() + 365 days - 1);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Should be 0 before cliff");

        vm.warp(token.vestingStart() + 365 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Should be fully vested at cliff=duration");

        vm.prank(address(0xa));
        token.release(0, 0);

        assertEq(token.balanceOf(address(0xa)), 1e24, "Should release full amount at cliff=duration");
    }

    // =========================================================================
    // Linear Vesting Tests
    // =========================================================================

    function test_linearVesting_25Percent() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.warp(token.vestingStart() + 365 days / 4);

        uint256 expected = 1e24 / 4;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected, "Wrong at 25%");

        vm.prank(address(0xa));
        token.release(0, 0);
        assertEq(token.balanceOf(address(0xa)), expected, "Wrong balance at 25%");
    }

    function test_linearVesting_50Percent() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.warp(token.vestingStart() + 365 days / 4);
        vm.prank(address(0xa));
        token.release(0, 0);

        vm.warp(token.vestingStart() + 365 days / 2);
        uint256 expectedAdditional = 1e24 / 2 - 1e24 / 4;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expectedAdditional, "Wrong at 50%");

        vm.prank(address(0xa));
        token.release(0, 0);
        assertEq(token.balanceOf(address(0xa)), 1e24 / 2, "Wrong total balance at 50%");
    }

    function test_linearVesting_100Percent() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.warp(token.vestingStart() + 365 days);

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Wrong at 100%");

        vm.prank(address(0xa));
        token.release(0, 0);
        assertEq(token.balanceOf(address(0xa)), 1e24, "Wrong balance at 100%");
    }

    function test_linearVesting_BeyondDuration() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.warp(token.vestingStart() + 730 days);

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

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        uint256 expected = 1e24 + 1e24;
        assertEq(token.computeAvailableVestedAmount(address(0xa)), expected, "Wrong total available");

        vm.prank(address(0xa));
        token.release(0);
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

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        token.release(0, 0);
        assertEq(token.balanceOf(address(0xa)), 1e24, "Should only get schedule 0");
        assertEq(token.computeAvailableVestedAmount(address(0xa), 1), 1e24, "Schedule 1 should still be available");
    }

    // =========================================================================
    // releaseFor Tests
    // =========================================================================

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

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xdead));
        token.releaseFor(address(0xa), 0);

        assertEq(token.balanceOf(address(0xa)), 2e24, "Should release all schedules");
    }

    // =========================================================================
    // Revert-on-Zero Tests
    // =========================================================================

    function test_revertOnZero_ReleaseWithScheduleId() public {
        _createSingleScheduleToken(address(0xa), 1e24, 365 days, 730 days);

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0, 0);
    }

    function test_revertOnZero_ReleaseNoArgs() public {
        _createSingleScheduleToken(address(0xa), 1e24, 365 days, 730 days);

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0);
    }

    function test_revertOnZero_AfterFullyClaimed() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.warp(token.vestingStart() + 365 days);

        vm.startPrank(address(0xa));
        token.release(0, 0);
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0, 0);
        vm.stopPrank();
    }

    function test_revertOnZero_NoAllocations() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        _createToken(schedules, _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0);
    }

    // =========================================================================
    // Permit2 Tests
    // =========================================================================

    function test_permit2_InfiniteAllowance() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        assertEq(token.allowance(RECIPIENT, permit2), type(uint256).max, "Permit2 should have infinite allowance");
    }

    // =========================================================================
    // Additional Balance Limit Tests
    // =========================================================================

    function test_balanceLimit_CustomExclusionsAppliedAtInitialize() public {
        address[] memory excluded = new address[](1);
        excluded[0] = address(0xbeef);

        _createToken(
            _emptySchedules(),
            _emptyAddresses(),
            _emptyUints(),
            _emptyUints(),
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            excluded
        );

        assertEq(token.maxBalanceLimit(), DEFAULT_MAX_BALANCE_LIMIT, "Wrong max balance limit");
        assertEq(token.balanceLimitEnd(), _defaultLimitEnd(), "Wrong limit end");
        assertEq(token.controller(), CONTROLLER, "Wrong controller");
        assertTrue(token.isExcludedFromBalanceLimit(address(0xbeef)), "Custom exclusion missing");
    }

    function test_balanceLimit_ReleaseToBeneficiaryIgnoresCapBecauseBeneficiaryExcluded() public {
        _createSingleScheduleTokenWithBalanceLimit(
            address(0xa),
            DEFAULT_MAX_BALANCE_LIMIT + 1,
            0,
            365 days,
            DEFAULT_MAX_BALANCE_LIMIT,
            _defaultLimitEnd(),
            CONTROLLER,
            _emptyAddresses()
        );

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        token.release(0, 0);

        assertTrue(token.isExcludedFromBalanceLimit(address(0xa)), "Beneficiary should be excluded");
        assertEq(
            token.balanceOf(address(0xa)), DEFAULT_MAX_BALANCE_LIMIT + 1, "Release should bypass cap for beneficiary"
        );
    }

    // =========================================================================
    // Regression Tests
    // =========================================================================

    function test_regression_InflationAfterVesting() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.warp(token.vestingStart() + 365 days);
        vm.prank(address(0xa));
        token.release(0, 0);

        vm.prank(OWNER);
        token.unlockPool();

        vm.warp(block.timestamp + 365 days);
        token.mintInflation();

        assertTrue(token.balanceOf(OWNER) > 0, "Owner should have inflation tokens");
    }

    function test_regression_BurnAfterRelease() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.prank(OWNER);
        token.lockPool(address(0xdeadbeef));
        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        token.release(0, 0);

        uint256 balanceBefore = token.balanceOf(address(0xa));
        uint256 supplyBefore = token.totalSupply();
        uint256 burnAmount = balanceBefore / 2;

        vm.prank(address(0xa));
        token.burn(burnAmount);

        assertEq(token.balanceOf(address(0xa)), balanceBefore - burnAmount, "Balance should decrease by burn amount");
        assertEq(token.totalSupply(), supplyBefore - burnAmount, "Total supply should decrease by burn amount");
    }

    function test_regression_VoteDelegation() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        address delegatee = address(0xdead);

        vm.prank(RECIPIENT);
        token.delegate(delegatee);

        assertEq(token.delegates(RECIPIENT), delegatee, "Delegation should work");
        assertEq(token.getVotes(delegatee), INITIAL_SUPPLY, "Delegatee should have votes");
    }

    // =========================================================================
    // State Machine / Property Tests
    // =========================================================================

    function testFuzz_cliffGating_BlocksBeforeCliff(
        uint64 cliff,
        uint64 duration,
        uint256 totalAmount,
        uint64 elapsedBeforeCliff
    ) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        cliff = uint64(bound(cliff, 1, duration));
        totalAmount = bound(totalAmount, 1, _maxPerAddress());
        elapsedBeforeCliff = uint64(bound(elapsedBeforeCliff, 0, cliff - 1));

        _createSingleScheduleToken(address(0xa), totalAmount, cliff, duration);

        vm.warp(token.vestingStart() + elapsedBeforeCliff);

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Should be 0 before cliff");

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0, 0);
    }

    function testFuzz_cliffGating_AllowsAtAndAfterCliff(
        uint64 cliff,
        uint64 duration,
        uint256 totalAmount,
        uint64 elapsedAfterCliff
    ) public {
        cliff = uint64(bound(cliff, 0, 365 days));
        uint256 minDuration = cliff + 1 > MIN_VESTING_DURATION ? cliff + 1 : MIN_VESTING_DURATION;
        duration = uint64(bound(duration, minDuration, cliff + 365 days));
        totalAmount = bound(totalAmount, 1e18, _maxPerAddress());
        elapsedAfterCliff = uint64(bound(elapsedAfterCliff, 0, duration - cliff));

        _createSingleScheduleToken(address(0xa), totalAmount, cliff, duration);

        uint256 totalElapsed = uint256(cliff) + elapsedAfterCliff;
        vm.warp(token.vestingStart() + totalElapsed);

        uint256 expected = totalElapsed >= duration ? totalAmount : totalAmount * totalElapsed / duration;
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected, "Wrong available after cliff");

        if (expected > 0) {
            vm.prank(address(0xa));
            token.release(0, 0);
            assertEq(token.balanceOf(address(0xa)), expected, "Wrong balance after release");
        }
    }

    function testFuzz_multipleReleases_NeverExceedTotal(
        uint64 duration,
        uint256 totalAmount,
        uint8[5] memory releasePercents
    ) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        totalAmount = bound(totalAmount, 1e18, _maxPerAddress());

        _createSingleScheduleToken(address(0xa), totalAmount, 0, duration);

        uint256 totalReleased;
        uint256 lastPercent;

        for (uint256 i; i < 5; i++) {
            uint8 percent = uint8(bound(releasePercents[i], uint8(lastPercent), 100));
            lastPercent = percent;

            uint256 elapsed = uint256(duration) * percent / 100;
            vm.warp(token.vestingStart() + elapsed);

            uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
            if (available > 0) {
                vm.prank(address(0xa));
                token.release(0, 0);
                totalReleased += available;
            }
        }

        assertLe(totalReleased, totalAmount, "Released exceeds total");

        vm.warp(token.vestingStart() + duration);
        uint256 finalAvailable = token.computeAvailableVestedAmount(address(0xa), 0);
        if (finalAvailable > 0) {
            vm.prank(address(0xa));
            token.release(0, 0);
            totalReleased += finalAvailable;
        }

        assertEq(totalReleased, totalAmount, "Should release exactly total amount");
    }

    function testFuzz_property_ReleasedMonotonicallyIncreases(
        uint64 duration,
        uint256 totalAmount,
        uint8[3] memory releasePercents
    ) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        totalAmount = bound(totalAmount, 1e18, _maxPerAddress());

        _createSingleScheduleToken(address(0xa), totalAmount, 0, duration);

        uint256 lastReleased;
        uint256 lastPercent;

        for (uint256 i; i < 3; i++) {
            uint8 percent = uint8(bound(releasePercents[i], uint8(lastPercent), 100));
            lastPercent = percent;

            vm.warp(token.vestingStart() + (uint256(duration) * percent / 100));

            (, uint256 releasedBefore) = token.vestingOf(address(0xa), 0);
            uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);

            if (available > 0) {
                vm.prank(address(0xa));
                token.release(0, 0);
            }

            (, uint256 releasedAfter) = token.vestingOf(address(0xa), 0);
            assertGe(releasedAfter, releasedBefore, "Released must be monotonically increasing");
            assertGe(releasedAfter, lastReleased, "Released must never decrease");
            lastReleased = releasedAfter;
        }
    }

    function testFuzz_property_AvailableZeroAfterRelease(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, MIN_VESTING_DURATION, 365 days));

        _createSingleScheduleToken(address(0xa), 365e18, 0, 365 days);

        vm.warp(token.vestingStart() + elapsed);

        uint256 availableBefore = token.computeAvailableVestedAmount(address(0xa), 0);
        assertTrue(availableBefore > 0, "Should have available before release");

        vm.prank(address(0xa));
        token.release(0, 0);

        assertEq(
            token.computeAvailableVestedAmount(address(0xa), 0), 0, "Available should be 0 immediately after release"
        );
    }

    function testFuzz_multiSchedule_IndependentVesting(
        uint64 duration0,
        uint64 duration1,
        uint256 amount0,
        uint256 amount1,
        uint64 elapsed
    ) public {
        duration0 = uint64(bound(duration0, MIN_VESTING_DURATION, 365 days));
        duration1 = uint64(bound(duration1, MIN_VESTING_DURATION, 730 days));
        amount0 = bound(amount0, 1, _maxPerAddress() / 2);
        amount1 = bound(amount1, 1, _maxPerAddress() / 2);
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

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + elapsed);

        uint256 expected0 = elapsed >= duration0 ? amount0 : amount0 * elapsed / duration0;
        uint256 expected1 = elapsed >= duration1 ? amount1 : amount1 * elapsed / duration1;

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), expected0, "Schedule 0 mismatch");
        assertEq(token.computeAvailableVestedAmount(address(0xa), 1), expected1, "Schedule 1 mismatch");
        assertEq(token.computeAvailableVestedAmount(address(0xa)), expected0 + expected1, "Total mismatch");
    }

    function testFuzz_property_FullyVestedAvailable(uint256 totalAmount, uint64 extraTime) public {
        totalAmount = bound(totalAmount, 1e18, _maxPerAddress());
        extraTime = uint64(bound(extraTime, 0, 365 days));

        _createSingleScheduleToken(address(0xa), totalAmount, 0, 30 days);

        vm.warp(token.vestingStart() + 30 days + extraTime);

        (uint256 total, uint256 released) = token.vestingOf(address(0xa), 0);
        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(available, total - released, "Available should equal remaining when fully vested");
    }

    function test_property_ReleaseIdempotent() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(address(0xa));
        token.release(0, 0);
        uint256 balanceAfterFirst = token.balanceOf(address(0xa));

        vm.prank(address(0xa));
        vm.expectRevert(NoReleasableAmount.selector);
        token.release(0, 0);

        assertEq(token.balanceOf(address(0xa)), balanceAfterFirst, "Balance unchanged on failed release");
    }

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

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

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

        _createToken(schedules, beneficiaries, scheduleIds, amounts);

        vm.warp(token.vestingStart() + 365 days);

        vm.startPrank(address(0xa));
        token.release(0, 0);
        token.release(1, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(address(0xa)), 3e24, "Should have all tokens regardless of order");
    }

    function testFuzz_oracle_AvailableMatchesReference(uint64 duration, uint256 totalAmount, uint64 elapsed) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        totalAmount = bound(totalAmount, 1, _maxPerAddress());
        elapsed = uint64(bound(elapsed, 0, duration * 2));

        _createSingleScheduleToken(address(0xa), totalAmount, 0, duration);

        vm.warp(token.vestingStart() + elapsed);

        uint256 contractAvailable = token.computeAvailableVestedAmount(address(0xa), 0);
        uint256 referenceVested = elapsed >= duration ? totalAmount : totalAmount * elapsed / duration;

        assertEq(contractAvailable, referenceVested, "Contract should match reference");
    }

    // =========================================================================
    // Arithmetic / Boundary / Mutation Tests
    // =========================================================================

    function testFuzz_arithmetic_DivisionPrecision(uint64 duration, uint256 totalAmount, uint64 elapsed) public {
        duration = uint64(bound(duration, MIN_VESTING_DURATION, 365 days));
        totalAmount = bound(totalAmount, 1, _maxPerAddress());
        elapsed = uint64(bound(elapsed, 0, duration));

        _createSingleScheduleToken(address(0xa), totalAmount, 0, duration);

        vm.warp(token.vestingStart() + elapsed);

        uint256 available = token.computeAvailableVestedAmount(address(0xa), 0);
        uint256 expected = elapsed >= duration ? totalAmount : totalAmount * elapsed / duration;

        assertLe(available, totalAmount, "Available should never exceed total");
        assertEq(available, expected, "Available should match the reference vesting formula");
    }

    function test_arithmetic_LargeAmountsNoOverflow() public {
        uint256 maxPerAddress = _maxPerAddress();
        _createSingleScheduleToken(address(0xa), maxPerAddress, 0, 365 days);

        uint256[] memory testPoints = new uint256[](5);
        testPoints[0] = 1;
        testPoints[1] = 365 days / 4;
        testPoints[2] = 365 days / 2;
        testPoints[3] = 365 days * 3 / 4;
        testPoints[4] = 365 days;

        for (uint256 i; i < testPoints.length; i++) {
            vm.warp(token.vestingStart() + testPoints[i]);
            assertLe(token.computeAvailableVestedAmount(address(0xa), 0), maxPerAddress, "No overflow at test point");
        }
    }

    function test_edge_MinimumDuration() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, uint64(MIN_VESTING_DURATION));

        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Should be 0 at t=0");

        vm.warp(token.vestingStart() + 12 hours);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24 / 2, "Should be 50% at 12 hours");

        vm.warp(token.vestingStart() + 1 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Should be fully vested at 1 day");
    }

    function test_edge_ExactMaxPerAddressAllocation() public {
        uint256 maxPerAddress = _maxPerAddress();
        _createSingleScheduleToken(address(0xa), maxPerAddress, 0, 365 days);

        assertEq(token.totalAllocatedOf(address(0xa)), maxPerAddress, "Should allow exact max");
    }

    function test_edge_ManySchedulesGas() public {
        uint256 numSchedules = 20;
        uint256 numAllocations = 20;

        VestingSchedule[] memory schedules = new VestingSchedule[](numSchedules);
        for (uint256 i; i < numSchedules; i++) {
            schedules[i] = VestingSchedule({ cliff: uint64(i * 1 days), duration: uint64((i + 1) * 30 days) });
        }

        uint256 perAllocation = _maxPerAddress() / numAllocations;
        address[] memory beneficiaries = new address[](numAllocations);
        uint256[] memory scheduleIds = new uint256[](numAllocations);
        uint256[] memory amounts = new uint256[](numAllocations);

        for (uint256 i; i < numAllocations; i++) {
            beneficiaries[i] = address(0xa);
            scheduleIds[i] = i % numSchedules;
            amounts[i] = perAllocation;
        }

        uint256 gasBefore = gasleft();
        _createToken(schedules, beneficiaries, scheduleIds, amounts);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for 20 schedules, 20 allocations", gasUsed);

        vm.warp(token.vestingStart() + 365 days);
        assertTrue(token.computeAvailableVestedAmount(address(0xa)) > 0, "Should have available amount");

        vm.prank(address(0xa));
        token.release(0);
        assertTrue(token.balanceOf(address(0xa)) > 0, "Should have balance after release");
    }

    function test_edge_ExactTimestamps() public {
        _createSingleScheduleToken(address(0xa), 200e18, 100 days, 200 days);

        vm.warp(token.vestingStart() + 100 days);
        uint256 atCliff = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(atCliff, 100e18, "Should have 100 days worth at cliff");

        vm.prank(address(0xa));
        token.release(0, 0);

        vm.warp(token.vestingStart() + 200 days);
        uint256 atDuration = token.computeAvailableVestedAmount(address(0xa), 0);
        assertEq(atDuration, 100e18, "Should have remaining 100 days worth at duration");

        vm.prank(address(0xa));
        token.release(0, 0);

        assertEq(token.balanceOf(address(0xa)), 200e18, "Should have full amount");
    }

    function test_boundary_ExactCliffTimestamp() public {
        uint64 cliff = 30 days;
        uint64 duration = 365 days;

        _createSingleScheduleToken(address(0xa), 365e18, cliff, duration);
        uint256 start = token.vestingStart();

        vm.warp(start + cliff - 1);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "0 just before cliff");

        vm.warp(start + cliff);
        uint256 atCliff = token.computeAvailableVestedAmount(address(0xa), 0);
        uint256 expectedAtCliff = (365e18 * uint256(cliff)) / uint256(duration);
        assertEq(atCliff, expectedAtCliff, "cliff days of vesting at cliff");

        vm.warp(start + cliff + 1);
        uint256 afterCliff = token.computeAvailableVestedAmount(address(0xa), 0);
        assertGt(afterCliff, atCliff, "More should be available after cliff");
    }

    function test_boundary_ExactDurationTimestamp() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);
        uint256 start = token.vestingStart();

        vm.warp(start + 365 days - 1);
        assertLt(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Not fully vested before duration");

        vm.warp(start + 365 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Fully vested at duration");

        vm.warp(start + 730 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 1e24, "Capped after duration");
    }

    function test_boundary_NonBeneficiary() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        assertEq(token.computeAvailableVestedAmount(address(0xb), 0), 0, "Non-beneficiary: 0 per schedule");
        assertEq(token.computeAvailableVestedAmount(address(0xb)), 0, "Non-beneficiary: 0 total");
        assertEq(token.getScheduleIdsOf(address(0xb)).length, 0, "Non-beneficiary: no schedule IDs");
    }

    function test_mutation_CliffOffByOne() public {
        _createSingleScheduleToken(address(0xa), 200e18, 1 days, 2 days);
        uint256 start = token.vestingStart();

        vm.warp(start + 1 days);
        assertGt(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Claimable at cliff");

        vm.warp(start + 1 days - 1);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 0, "Not claimable before cliff");
    }

    function test_mutation_DurationOffByOne() public {
        _createSingleScheduleToken(address(0xa), 100e18, 0, 1 days);

        vm.warp(token.vestingStart() + 1 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 100e18, "Fully vested at duration");
    }

    function test_mutation_WrongVestingOperator() public {
        _createSingleScheduleToken(address(0xa), 100e18, 0, 100 days);

        vm.warp(token.vestingStart() + 50 days);
        assertEq(token.computeAvailableVestedAmount(address(0xa), 0), 50e18, "Exactly 50% at 50% duration");
    }

    // =========================================================================
    // ERC20 / Access / Miscellaneous Tests
    // =========================================================================

    function test_erc20_TransferReturnsBool() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(RECIPIENT);
        bool success = token.transfer(address(0xdead), 1);
        assertTrue(success, "transfer should return true");
    }

    function test_erc20_TransferFromReturnsBool() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(RECIPIENT);
        token.approve(address(this), 100);

        bool success = token.transferFrom(RECIPIENT, address(0xdead), 1);
        assertTrue(success, "transferFrom should return true");
    }

    function test_erc20_ApproveReturnsBool() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(RECIPIENT);
        bool success = token.approve(address(0xdead), 100);
        assertTrue(success, "approve should return true");
    }

    function test_erc20_DecimalsReturnsUint8() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        assertEq(token.decimals(), 18, "decimals should be 18");
    }

    function testFuzz_erc20_BalanceConsistency(uint256 transferAmount) public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

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

    function testFuzz_access_OnlyOwnerCanLockPool(address caller) public {
        vm.assume(caller != OWNER);

        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.lockPool(address(0xdead));
    }

    function testFuzz_access_OnlyOwnerCanUnlockPool(address caller) public {
        vm.assume(caller != OWNER);

        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.unlockPool();
    }

    function testFuzz_access_OnlyOwnerCanUpdateMintRate(address caller, uint256 newRate) public {
        vm.assume(caller != OWNER);
        newRate = bound(newRate, 0, 0.02 ether);

        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.updateMintRate(newRate);
    }

    function testFuzz_access_AnyoneCanReleaseFor(address caller) public {
        vm.assume(caller != address(0));

        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.warp(token.vestingStart() + 365 days);

        vm.prank(caller);
        token.releaseFor(address(0xa), 0, 0);

        assertEq(token.balanceOf(address(0xa)), 1e24, "Beneficiary should receive tokens");
    }

    function test_mintInflation_MultipleYears() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(OWNER);
        token.unlockPool();

        vm.warp(block.timestamp + (365 days * 3));
        token.mintInflation();

        assertTrue(token.balanceOf(OWNER) > 0, "Should mint for multiple years");
    }

    function test_mintInflation_RevertsWhenCalledTwiceInSameBlock() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(OWNER);
        token.unlockPool();

        vm.warp(block.timestamp + 365 days);
        token.mintInflation();

        vm.expectRevert(NoMintableAmount.selector);
        token.mintInflation();
    }

    function test_updateMintRate_ToZero() public {
        _createToken(_emptySchedules(), _emptyAddresses(), _emptyUints(), _emptyUints());

        vm.prank(OWNER);
        token.updateMintRate(0);

        assertEq(token.yearlyMintRate(), 0, "Should allow zero mint rate");
    }

    function test_vestingScheduleCount_WithMultipleSchedules() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](3);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 180 days, duration: 730 days });
        schedules[2] = VestingSchedule({ cliff: 365 days, duration: 1460 days });

        _createToken(schedules, _emptyAddresses(), _emptyUints(), _emptyUints());

        assertEq(token.vestingScheduleCount(), 3, "Should return correct schedule count");
    }

    function test_votingPower_VestedTokensNotCountedBeforeRelease() public {
        _createSingleScheduleToken(address(0xa), 1e24, 0, 365 days);

        vm.prank(address(0xa));
        token.delegate(address(0xa));

        assertEq(token.getVotes(address(0xa)), 0, "Vested but unreleased tokens shouldn't count");
    }
}
