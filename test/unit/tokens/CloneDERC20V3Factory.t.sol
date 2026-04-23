// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { CloneDERC20V3, MAX_YEARLY_MINT_RATE_WAD, VestingSchedule } from "src/tokens/CloneDERC20V3.sol";
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
