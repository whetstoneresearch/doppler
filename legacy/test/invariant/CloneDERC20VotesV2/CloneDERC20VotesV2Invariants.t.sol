// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import {
    CloneDERC20VotesV2,
    MAX_PRE_MINT_PER_ADDRESS_WAD,
    MAX_TOTAL_PRE_MINT_WAD,
    MAX_YEARLY_MINT_RATE_WAD,
    MIN_VESTING_DURATION,
    VestingData,
    VestingSchedule
} from "src/tokens/CloneDERC20VotesV2.sol";
import { WAD } from "src/types/Wad.sol";
import { AddressSet, LibAddressSet } from "test/invariant/AddressSet.sol";
import { CloneDERC20VotesV2Handler } from "test/invariant/CloneDERC20VotesV2/CloneDERC20VotesV2Handler.sol";

/**
 * @title CloneDERC20V2InvariantsTest
 * @notice Invariant tests for CloneDERC20VotesV2 multi-schedule vesting
 * @dev Tests critical properties that must always hold regardless of action sequence
 */
contract CloneDERC20V2InvariantsTest is Test {
    using LibAddressSet for AddressSet;

    CloneDERC20VotesV2 public token;
    CloneDERC20VotesV2Handler public handler;

    uint256 initialSupply;
    uint256 yearlyMintRate;

    address public owner = makeAddr("owner");
    address public recipient = makeAddr("recipient");

    address[] public beneficiaries;
    VestingSchedule[] public schedules;
    uint256[] public scheduleIds;
    uint256[] public amounts;

    AddressSet internal filteredBeneficiaries;

    function setUp() public {
        initialSupply = vm.randomUint(1e18, 1e30);
        yearlyMintRate = vm.randomUint(0, MAX_YEARLY_MINT_RATE_WAD);

        // Create diverse vesting schedules
        for (uint256 i; i < vm.randomUint(1, 10); i++) {
            uint64 duration = vm.randomBool() ? 0 : uint64(vm.randomUint(MIN_VESTING_DURATION, 4 * 365 days));
            uint64 cliff = uint64(vm.randomUint(0, duration));
            schedules.push(VestingSchedule({ cliff: cliff, duration: duration }));
        }

        uint256 maxPreMintPerAddress = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / WAD;
        uint256 maxTotalPreMint = initialSupply * MAX_TOTAL_PRE_MINT_WAD / WAD;

        uint256 preMintLeft = maxTotalPreMint;

        for (uint256 i; i < vm.randomUint(0, 100); i++) {
            address beneficiary = vm.randomAddress();
            beneficiaries.push(beneficiary);

            if (!filteredBeneficiaries.contains(beneficiary)) {
                filteredBeneficiaries.add(beneficiary);
            }

            scheduleIds.push(vm.randomUint(0, schedules.length - 1));
            uint256 amount = vm.randomUint(1, maxPreMintPerAddress > preMintLeft ? preMintLeft : maxPreMintPerAddress);
            amounts.push(amount);
            preMintLeft -= amount;

            if (preMintLeft == 0) {
                break;
            }
        }

        token = new CloneDERC20VotesV2();

        // Deploy token
        token.initialize(
            "Invariant Test Token",
            "ITT",
            initialSupply,
            recipient,
            owner,
            yearlyMintRate,
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            "https://example.com/token"
        );

        // Deploy handler
        handler = new CloneDERC20VotesV2Handler(token, filteredBeneficiaries.addrs);

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

    function invariant_BalanceDoesNotExceedVestedAmount() public view {
        for (uint256 i; i < filteredBeneficiaries.count(); i++) {
            address beneficiary = filteredBeneficiaries.addrs[i];
            uint256 balance = token.balanceOf(beneficiary);
            uint256 vestedAmount = token.totalAllocatedOf(beneficiary);
            assertLe(balance, vestedAmount, "Beneficiary balance exceeds vested amount");
        }
    }
}
