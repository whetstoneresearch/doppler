// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import {
    ArrayLengthsMismatch,
    BalanceLimitExceeded,
    CloneDERC20V3,
    InvalidBalanceLimit,
    MAX_YEARLY_MINT_RATE_WAD,
    MaxYearlyMintRateExceeded,
    VestingSchedule
} from "src/tokens/CloneDERC20V3.sol";
import { CloneDERC20V3Factory } from "src/tokens/CloneDERC20V3Factory.sol";
import { generateRecipients } from "test/unit/tokens/CloneERC20Votes.t.sol";

contract CloneDERC20V3FactoryTest is Test {
    address internal AIRLOCK = makeAddr("Airlock");
    CloneDERC20V3Factory internal factory;

    function setUp() public {
        factory = new CloneDERC20V3Factory(AIRLOCK);
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(factory.airlock()), AIRLOCK, "Wrong Airlock");
        assertNotEq(factory.IMPLEMENTATION(), address(0), "Implementation not set");
    }

    /* ---------------------------------------------------------------------- */
    /*                                create()                                */
    /* ---------------------------------------------------------------------- */

    function test_create() public {
        string memory name = "Test V3";
        string memory symbol = "TV3";
        uint256 initialSupply = 1e26;
        address recipient = address(0xa71ce);
        address owner = address(0xb0b);
        uint256 yearlyMintRate = MAX_YEARLY_MINT_RATE_WAD;
        string memory tokenURI = "ipfs://clone-v3";
        bytes32 salt = bytes32(uint256(1234));
        uint256 maxBalanceLimit = 5e23;
        uint48 balanceLimitEnd = uint48(block.timestamp + 7 days);
        address controller = address(0xc0ffee);
        address beneficiary = address(0xbeef);
        address extraExcluded = address(0xfeed);

        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = beneficiary;

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = maxBalanceLimit + 1;

        address[] memory excludedFromBalanceLimit = new address[](1);
        excludedFromBalanceLimit[0] = extraExcluded;

        bytes memory tokenData = abi.encode(
            name,
            symbol,
            yearlyMintRate,
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            tokenURI,
            maxBalanceLimit,
            balanceLimitEnd,
            controller,
            excludedFromBalanceLimit
        );

        vm.prank(AIRLOCK);
        CloneDERC20V3 token = CloneDERC20V3(factory.create(initialSupply, recipient, owner, salt, tokenData));

        address predicted = LibClone.predictDeterministicAddress(factory.IMPLEMENTATION(), salt, address(factory));
        assertEq(address(token), predicted, "Asset address mismatch");
        assertEq(token.name(), name, "Wrong name");
        assertEq(token.symbol(), symbol, "Wrong symbol");
        assertEq(token.tokenURI(), tokenURI, "Wrong token URI");
        assertEq(token.totalSupply(), initialSupply, "Wrong total supply");
        assertEq(token.owner(), owner, "Wrong owner");
        assertEq(token.yearlyMintRate(), yearlyMintRate, "Wrong yearly mint rate");
        assertEq(token.maxBalanceLimit(), maxBalanceLimit, "Wrong balance limit");
        assertEq(token.balanceLimitEnd(), balanceLimitEnd, "Wrong balance limit end");
        assertEq(token.controller(), controller, "Wrong controller");
        assertEq(token.isBalanceLimitActive(), true, "Balance limit should be active");
        assertEq(token.balanceOf(recipient), initialSupply - amounts[0], "Wrong recipient balance");
        assertEq(token.balanceOf(address(token)), amounts[0], "Wrong vested token balance");
        assertEq(token.isExcludedFromBalanceLimit(owner), true, "Owner should be excluded");
        assertEq(token.isExcludedFromBalanceLimit(recipient), true, "Recipient should be excluded");
        assertEq(token.isExcludedFromBalanceLimit(beneficiary), true, "Beneficiary should be excluded");
        assertEq(token.isExcludedFromBalanceLimit(extraExcluded), true, "Explicit exclusion missing");
    }

    function test_create_RevertsIfSenderNotAirlock() public {
        vm.expectRevert(SenderNotAirlock.selector);
        factory.create(0, address(0), address(0), bytes32(0), new bytes(0));
    }

    function test_create_RevertsOnDuplicateSalt() public {
        bytes32 salt = bytes32(uint256(1234));
        bytes memory tokenData = abi.encode(
            "Test V3",
            "TV3",
            uint256(0),
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            "ipfs://clone-v3",
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );

        address predicted = LibClone.predictDeterministicAddress(factory.IMPLEMENTATION(), salt, address(factory));

        vm.startPrank(AIRLOCK);
        factory.create(1e26, address(0xa71ce), address(0xb0b), salt, tokenData);
        assertGt(predicted.code.length, 0, "First create should deploy the clone");
        vm.expectRevert(LibClone.DeploymentFailed.selector);
        factory.create(1e26, address(0xa71ce), address(0xb0b), salt, tokenData);
        vm.stopPrank();
    }

    function test_create_RevertedInitializationDoesNotLeaveCloneCode() public {
        bytes32 salt = bytes32(uint256(5678));
        bytes memory tokenData = abi.encode(
            "Test V3",
            "TV3",
            MAX_YEARLY_MINT_RATE_WAD + 1,
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            "ipfs://clone-v3",
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );
        address predicted = LibClone.predictDeterministicAddress(factory.IMPLEMENTATION(), salt, address(factory));

        vm.prank(AIRLOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxYearlyMintRateExceeded.selector, MAX_YEARLY_MINT_RATE_WAD + 1, MAX_YEARLY_MINT_RATE_WAD
            )
        );
        factory.create(1e26, address(0xa71ce), address(0xb0b), salt, tokenData);

        assertEq(predicted.code.length, 0, "Reverted initialization should roll back clone deployment");
    }

    function test_create_RevertsWhenDecodedArraysMismatch() public {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(0xbeef);

        bytes memory tokenData = abi.encode(
            "Test V3",
            "TV3",
            uint256(0),
            schedules,
            beneficiaries,
            new uint256[](0),
            new uint256[](1),
            "ipfs://clone-v3",
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );

        vm.prank(AIRLOCK);
        vm.expectRevert(ArrayLengthsMismatch.selector);
        factory.create(1e26, address(0xa71ce), address(0xb0b), bytes32(uint256(91_011)), tokenData);
    }

    function test_create_RevertsWhenDecodedBalanceLimitInvalid() public {
        bytes memory tokenData = abi.encode(
            "Test V3",
            "TV3",
            uint256(0),
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            "ipfs://clone-v3",
            uint256(0),
            uint48(block.timestamp + 7 days),
            address(0xc0ffee),
            new address[](0)
        );

        vm.prank(AIRLOCK);
        vm.expectRevert(abi.encodeWithSelector(InvalidBalanceLimit.selector, 0));
        factory.create(1e26, address(0xa71ce), address(0xb0b), bytes32(uint256(121_314)), tokenData);
    }

    function test_create_ControllerCanDisableActiveBalanceLimit() public {
        uint256 initialSupply = 1e26;
        uint256 maxBalanceLimit = 5e23;
        address recipient = address(0xa71ce);
        address owner = address(0xb0b);
        address controller = address(0xc0ffee);

        bytes memory tokenData = abi.encode(
            "Test V3",
            "TV3",
            uint256(0),
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            "ipfs://clone-v3",
            maxBalanceLimit,
            uint48(block.timestamp + 7 days),
            controller,
            new address[](0)
        );

        vm.prank(AIRLOCK);
        CloneDERC20V3 token =
            CloneDERC20V3(factory.create(initialSupply, recipient, owner, bytes32(uint256(151_617)), tokenData));

        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(BalanceLimitExceeded.selector, maxBalanceLimit + 1, maxBalanceLimit));
        token.transfer(address(0xbeef), maxBalanceLimit + 1);

        vm.prank(controller);
        token.disableBalanceLimit();

        vm.prank(recipient);
        token.transfer(address(0xbeef), maxBalanceLimit + 1);

        assertEq(token.balanceOf(address(0xbeef)), maxBalanceLimit + 1, "Controller should disable cap");
    }

    function test_create_MultipleSchedulesAndBeneficiaries() public {
        uint256 initialSupply = 1e26;
        address recipient = address(0xa71ce);
        address owner = address(0xb0b);
        address beneficiaryA = address(0xa);
        address beneficiaryB = address(0xb);

        VestingSchedule[] memory schedules = new VestingSchedule[](2);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });
        schedules[1] = VestingSchedule({ cliff: 30 days, duration: 730 days });

        address[] memory beneficiaries = new address[](3);
        beneficiaries[0] = beneficiaryA;
        beneficiaries[1] = beneficiaryB;
        beneficiaries[2] = beneficiaryA;

        uint256[] memory scheduleIds = new uint256[](3);
        scheduleIds[0] = 0;
        scheduleIds[1] = 0;
        scheduleIds[2] = 1;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e24;
        amounts[1] = 2e24;
        amounts[2] = 3e24;

        bytes memory tokenData = abi.encode(
            "Test V3",
            "TV3",
            uint256(0),
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            "ipfs://clone-v3",
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );

        vm.prank(AIRLOCK);
        CloneDERC20V3 token =
            CloneDERC20V3(factory.create(initialSupply, recipient, owner, bytes32(uint256(181_920)), tokenData));

        assertEq(token.vestingScheduleCount(), 2, "Wrong schedule count");
        assertEq(token.vestedTotalAmount(), 6e24, "Wrong vested total");
        assertEq(token.balanceOf(address(token)), 6e24, "Wrong vested balance");
        assertEq(token.balanceOf(recipient), initialSupply - 6e24, "Wrong recipient balance");
        assertEq(token.totalAllocatedOf(beneficiaryA), 4e24, "Wrong beneficiary A allocation");
        assertEq(token.totalAllocatedOf(beneficiaryB), 2e24, "Wrong beneficiary B allocation");

        (uint256 totalA0,) = token.vestingOf(beneficiaryA, 0);
        (uint256 totalA1,) = token.vestingOf(beneficiaryA, 1);
        (uint256 totalB0,) = token.vestingOf(beneficiaryB, 0);
        assertEq(totalA0, 1e24, "Wrong beneficiary A schedule 0 amount");
        assertEq(totalA1, 3e24, "Wrong beneficiary A schedule 1 amount");
        assertEq(totalB0, 2e24, "Wrong beneficiary B schedule 0 amount");

        uint256[] memory idsA = token.getScheduleIdsOf(beneficiaryA);
        uint256[] memory idsB = token.getScheduleIdsOf(beneficiaryB);
        assertEq(idsA.length, 2, "Wrong beneficiary A schedule IDs");
        assertEq(idsA[0], 0, "Wrong beneficiary A first schedule");
        assertEq(idsA[1], 1, "Wrong beneficiary A second schedule");
        assertEq(idsB.length, 1, "Wrong beneficiary B schedule IDs");
        assertEq(idsB[0], 0, "Wrong beneficiary B schedule");
    }

    function testFuzz_create(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        address owner,
        uint256 yearlyMintRate,
        string memory tokenURI,
        uint256 seed
    ) public {
        initialSupply = bound(initialSupply, 1e18 + 1, type(uint128).max);
        vm.assume(recipient != address(0));
        vm.assume(owner != address(0));
        vm.assume(yearlyMintRate <= MAX_YEARLY_MINT_RATE_WAD);

        (, address[] memory recipients, uint256[] memory amounts) = generateRecipients(seed, initialSupply);
        uint256[] memory scheduleIds = new uint256[](recipients.length);
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 365 days });

        bytes memory tokenData = abi.encode(
            name,
            symbol,
            yearlyMintRate,
            schedules,
            recipients,
            scheduleIds,
            amounts,
            tokenURI,
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );

        vm.prank(AIRLOCK);
        vm.startSnapshotGas("TokenFactory", "CloneDERC20V3/Recipients");
        CloneDERC20V3 token = CloneDERC20V3(factory.create(initialSupply, recipient, owner, bytes32(seed), tokenData));
        vm.stopSnapshotGas("TokenFactory", "CloneDERC20V3/Recipients");

        address predicted =
            LibClone.predictDeterministicAddress(factory.IMPLEMENTATION(), bytes32(seed), address(factory));
        assertEq(address(token), predicted, "Asset address mismatch");
        assertEq(token.name(), name, "Wrong name");
        assertEq(token.symbol(), symbol, "Wrong symbol");
        assertEq(token.tokenURI(), tokenURI, "Wrong token URI");
        assertEq(token.totalSupply(), initialSupply, "Wrong total supply");
        assertEq(token.owner(), owner, "Wrong owner");
        assertEq(token.yearlyMintRate(), yearlyMintRate, "Wrong yearly mint rate");
        assertEq(token.vestingStart(), block.timestamp, "Wrong vesting start");
        assertEq(token.lastMintTimestamp(), 0, "Wrong mint timestamp");
        assertFalse(token.isBalanceLimitActive(), "Balance limit should be inactive");
    }

    function testFuzz_create_WithActiveBalanceLimit(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        address owner,
        uint256 yearlyMintRate,
        string memory tokenURI,
        uint256 maxBalanceLimit,
        address controller,
        uint256 seed
    ) public {
        initialSupply = bound(initialSupply, 1e18 + 1, type(uint128).max);
        vm.assume(recipient != address(0));
        vm.assume(owner != address(0));
        vm.assume(yearlyMintRate <= MAX_YEARLY_MINT_RATE_WAD);
        maxBalanceLimit = bound(maxBalanceLimit, 1, initialSupply - 1);

        bytes memory tokenData = abi.encode(
            name,
            symbol,
            yearlyMintRate,
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            tokenURI,
            maxBalanceLimit,
            uint48(block.timestamp + 7 days),
            controller,
            new address[](0)
        );

        vm.prank(AIRLOCK);
        CloneDERC20V3 token = CloneDERC20V3(factory.create(initialSupply, recipient, owner, bytes32(seed), tokenData));

        assertEq(token.maxBalanceLimit(), maxBalanceLimit, "Wrong balance limit");
        assertEq(token.controller(), controller, "Wrong controller");
        assertTrue(token.isBalanceLimitActive(), "Balance limit should be active");
        assertTrue(token.isExcludedFromBalanceLimit(owner), "Owner should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(recipient), "Recipient should be excluded");
    }
}
