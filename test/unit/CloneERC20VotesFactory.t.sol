// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { CloneERC20VotesFactory } from "src/CloneERC20VotesFactory.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import {
    CloneERC20Votes,
    ArrayLengthsMismatch,
    MaxPreMintPerAddressExceeded,
    MaxTotalPreMintExceeded,
    MAX_PRE_MINT_PER_ADDRESS_WAD,
    PoolLocked,
    MintingNotStartedYet,
    NoMintableAmount,
    MAX_YEARLY_MINT_RATE_WAD,
    MAX_TOTAL_PRE_MINT_WAD,
    MaxYearlyMintRateExceeded
} from "src/CloneERC20Votes.sol";
import { generateRecipients } from "test/unit/CloneERC20Votes.t.sol";

contract CloneERC20VotesFactoryTest is Test {
    address internal AIRLOCK = makeAddr("Airlock");
    CloneERC20VotesFactory internal factory;

    function setUp() public {
        factory = new CloneERC20VotesFactory(AIRLOCK);
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

    function testFuzz_create(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        address owner,
        uint256 yearlyMintRate,
        uint256 vestingDuration,
        string memory tokenURI,
        uint256 seed
    ) public {
        vm.assume(initialSupply > 0);
        vm.assume(recipient != address(0));
        vm.assume(owner != address(0));

        vm.assume(initialSupply < type(uint256).max / MAX_TOTAL_PRE_MINT_WAD);
        vm.assume(yearlyMintRate <= MAX_YEARLY_MINT_RATE_WAD);

        (uint256 totalPreMint, address[] memory recipients, uint256[] memory amounts) =
            generateRecipients(seed, initialSupply);

        bytes memory tokenData =
            abi.encode(name, symbol, yearlyMintRate, vestingDuration, recipients, amounts, tokenURI);

        vm.prank(AIRLOCK);
        CloneERC20Votes token =
            CloneERC20Votes(factory.create(initialSupply, recipient, owner, bytes32(seed), tokenData));

        address asset = LibClone.predictDeterministicAddress(factory.IMPLEMENTATION(), bytes32(seed), address(factory));
        require(address(token) == asset, "Asset address mismatch");

        assertEq(token.name(), name, "Wrong name");
        assertEq(token.symbol(), symbol, "Wrong symbol");
        assertEq(token.tokenURI(), tokenURI, "Wrong token URI");
        assertEq(token.totalSupply(), initialSupply, "Wrong total supply");
        assertEq(token.balanceOf(recipient), initialSupply - totalPreMint, "Wrong balance of recipient");
        assertEq(token.balanceOf(address(token)), totalPreMint, "Wrong balance of vested tokens");
        assertEq(token.lastMintTimestamp(), 0, "Wrong mint timestamp");
        assertEq(token.owner(), owner, "Wrong owner");
        assertEq(token.yearlyMintRate(), yearlyMintRate, "Wrong yearly mint cap");
        assertEq(token.vestingStart(), block.timestamp, "Wrong vesting start");
        assertEq(token.vestingDuration(), vestingDuration, "Wrong vesting duration");

        for (uint256 i; i < recipients.length; i++) {
            (uint256 totalAmount, uint256 releasedAmount) = token.getVestingDataOf(recipients[i]);
            assertEq(totalAmount, amounts[i], "Wrong vesting total amount for recipient");
            assertEq(releasedAmount, 0, "Wrong released amount for recipient");
        }
    }

    function testFuzz_create_RevertsIfSenderNotAirlock() public {
        vm.expectRevert(SenderNotAirlock.selector);
        factory.create(0, address(0), address(0), bytes32(0), new bytes(0));
    }
}
