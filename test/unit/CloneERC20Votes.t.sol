// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Ownable } from "@solady/auth/Ownable.sol";
import { ERC20Votes } from "@solady/tokens/ERC20Votes.sol";
import { Initializable } from "@solady/utils/Initializable.sol";
import { Test } from "forge-std/Test.sol";
import {
    ArrayLengthsMismatch,
    MAX_PRE_MINT_PER_ADDRESS_WAD,
    MAX_TOTAL_PRE_MINT_WAD,
    MAX_YEARLY_MINT_RATE_WAD,
    MaxPreMintPerAddressExceeded,
    MaxTotalPreMintExceeded,
    MaxYearlyMintRateExceeded,
    MintingNotStartedYet,
    NoMintableAmount
} from "src/tokens/CloneERC20.sol";
import { CloneERC20Votes } from "src/tokens/CloneERC20Votes.sol";

function generateRecipients(
    uint256 seed,
    uint256 initialSupply
) pure returns (uint256 totalPreMint, address[] memory recipients, uint256[] memory amounts) {
    uint256 length = seed % 500;

    address[] memory _recipients = new address[](length);
    uint256[] memory _amounts = new uint256[](length);

    uint256 maxPreMintPerAddress = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1 ether;
    uint256 maxTotalPreMint = initialSupply * MAX_TOTAL_PRE_MINT_WAD / 1 ether;

    uint256 actualLength;

    for (uint256 i; i < length; ++i) {
        uint256 amount = uint256(keccak256(abi.encode(seed, i))) % maxPreMintPerAddress;
        if (amount > maxTotalPreMint) amount = maxTotalPreMint;
        totalPreMint += amount;

        _recipients[i] = address(uint160(address(0xbeef)) + uint160(i));
        _amounts[i] = amount;
        maxTotalPreMint -= amount;
        actualLength++;

        if (maxTotalPreMint == 0) break;
    }

    recipients = new address[](actualLength);
    amounts = new uint256[](actualLength);

    for (uint256 i; i < actualLength; ++i) {
        recipients[i] = _recipients[i];
        amounts[i] = _amounts[i];
    }
}

uint256 constant MIN_INITIAL_SUPPLY = 1e18;

contract CloneERC20VotesTest is Test {
    CloneERC20Votes public token;

    function setUp() public {
        token = new CloneERC20Votes();
    }

    /* -------------------------------------------------------------------------- */
    /*                                initialize()                                */
    /* -------------------------------------------------------------------------- */

    function testFuzz_initialize(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        address owner,
        uint256 yearlyMintRate,
        uint256 vestingDuration,
        string memory tokenURI,
        uint256 seed
    ) public returns (uint256 totalPreMint, address[] memory recipients, uint256[] memory amounts) {
        vm.assume(initialSupply > MIN_INITIAL_SUPPLY);
        vm.assume(initialSupply < type(uint128).max);
        vm.assume(initialSupply < type(uint256).max / MAX_TOTAL_PRE_MINT_WAD);
        vm.assume(yearlyMintRate <= MAX_YEARLY_MINT_RATE_WAD);

        (totalPreMint, recipients, amounts) = generateRecipients(seed, initialSupply);

        vm.expectEmit();
        emit Ownable.OwnershipTransferred(address(0), owner);
        vm.expectEmit();
        emit Initializable.Initialized(1);
        token.initialize(
            name,
            symbol,
            initialSupply,
            recipient,
            owner,
            yearlyMintRate,
            vestingDuration,
            recipients,
            amounts,
            tokenURI
        );

        assertEq(token.name(), name, "Wrong name");
        assertEq(token.symbol(), symbol, "Wrong symbol");
        assertEq(token.tokenURI(), tokenURI, "Wrong token URI");
        assertEq(token.totalSupply(), initialSupply, "Wrong total supply");
        assertEq(token.balanceOf(recipient), initialSupply - totalPreMint, "Wrong balance of recipient");
        assertEq(token.balanceOf(address(token)), totalPreMint, "Wrong balance of vested tokens");
        assertEq(token.lastMintTimestamp(), 0, "Wrong mint timestamp");
        assertEq(token.owner(), owner, "Wrong owner");
        assertEq(token.yearlyMintRate(), yearlyMintRate, "Wrong yearly mint rate");
        assertEq(token.vestingStart(), block.timestamp, "Wrong vesting start");
        assertEq(token.vestingDuration(), vestingDuration, "Wrong vesting duration");

        for (uint256 i; i < recipients.length; i++) {
            (uint256 totalAmount, uint256 releasedAmount) = token.getVestingDataOf(recipients[i]);
            assertEq(totalAmount, amounts[i], "Wrong vesting total amount for recipient");
            assertEq(releasedAmount, 0, "Wrong released amount for recipient");
        }
    }

    function testFuzz_initialize_RevertsIfInvalidInitialization(
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
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );

        address[] memory recipients = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(
            name,
            symbol,
            initialSupply,
            recipient,
            owner,
            yearlyMintRate,
            vestingDuration,
            recipients,
            amounts,
            tokenURI
        );
    }

    function test_initialize_RevertsWhenArrayLengthsMismatch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xa);
        recipients[1] = address(0xb);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e23;

        vm.expectRevert(ArrayLengthsMismatch.selector);
        token.initialize("", "", 0, address(0), address(0), 0, 0, recipients, amounts, "");
    }

    function testFuzz_initialize_RevertsWhenMaxPreMintPerAddressExceeded(uint256 initialSupply) public {
        vm.assume(initialSupply > MIN_INITIAL_SUPPLY);
        vm.assume(initialSupply < type(uint256).max / MAX_TOTAL_PRE_MINT_WAD);

        address[] memory recipients = new address[](1);
        recipients[0] = address(0xa);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18 + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                MaxPreMintPerAddressExceeded.selector, amounts[0], initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18
            )
        );
        token.initialize("", "", initialSupply, address(0), address(0), 0, 0, recipients, amounts, "");
    }

    function testFuzz_initialize_RevertsWhenMaxPreMintPerAddressExceededReusingAddress(uint256 initialSupply) public {
        vm.assume(initialSupply > MIN_INITIAL_SUPPLY);
        vm.assume(initialSupply < type(uint256).max / MAX_TOTAL_PRE_MINT_WAD);

        address[] memory recipients = new address[](2);
        recipients[0] = address(0xa);
        recipients[1] = address(0xa);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        amounts[1] = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;

        vm.expectRevert(abi.encodeWithSelector(MaxPreMintPerAddressExceeded.selector, amounts[0] * 2, amounts[0]));
        token.initialize("", "", initialSupply, address(0), address(0), 0, 0, recipients, amounts, "");
    }

    function testFuzz_initialize_RevertsWhenMaxTotalPreMintExceeded(uint256 initialSupply) public {
        vm.assume(initialSupply > MIN_INITIAL_SUPPLY);
        vm.assume(initialSupply < type(uint256).max / MAX_TOTAL_PRE_MINT_WAD);

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        recipients[0] = address(0xa);
        recipients[1] = address(0xb);
        amounts[0] = amounts[1] = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;

        vm.expectRevert(
            abi.encodeWithSelector(
                MaxTotalPreMintExceeded.selector,
                initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18 * 2,
                initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18
            )
        );
        token.initialize("", "", initialSupply, address(0), address(0), 0, 0, recipients, amounts, "");
    }

    /* ------------------------------------------------------------------------ */
    /*                                lockPool()                                */
    /* ------------------------------------------------------------------------ */

    function test_lockPool_PassesWhenValidOwner(address pool) public {
        token.initialize("", "", 0, address(0), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.lockPool(pool);
    }

    function test_lockPool_RevertsWhenInvalidOwner(address pool) public {
        token.initialize("", "", 0, address(0), address(this), 0, 0, new address[](0), new uint256[](0), "");
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.Unauthorized.selector));
        token.lockPool(pool);
    }

    /* -------------------------------------------------------------------------- */
    /*                                unlockPool()                                */
    /* -------------------------------------------------------------------------- */

    function testFuzz_unlockPool(address pool) public {
        test_lockPool_PassesWhenValidOwner(pool);
        token.unlockPool();
        assertEq(token.lastMintTimestamp(), block.timestamp, "Inflation should have started");
        assertEq(token.currentYearStart(), block.timestamp, "Current year start should be the current timestamp");
    }

    function testFuzz_unlockPool_RevertsWhenInvalidOwner(address pool) public {
        test_lockPool_PassesWhenValidOwner(pool);
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.Unauthorized.selector));
        token.unlockPool();
    }

    /* ------------------------------------------------------------------------ */
    /*                                transfer()                                */
    /* ------------------------------------------------------------------------ */

    function test_transfer_ChangesDelegateVotes(
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
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );

        vm.startPrank(recipient);
        token.delegate(address(0xcafe));

        uint256 recipientBalance = token.balanceOf(recipient);
        uint256 previousVotes = token.getVotes(address(0xcafe));
        vm.expectEmit(true, true, true, true);
        emit ERC20Votes.DelegateVotesChanged(address(0xcafe), previousVotes, previousVotes - recipientBalance / 10);
        token.transfer(address(0xbeef), recipientBalance / 10);
        vm.stopPrank();
    }

    /* ---------------------------------------------------------------------------- */
    /*                                transferFrom()                                */
    /* ---------------------------------------------------------------------------- */

    function test_transferFrom_RevertsWhenPoolLocked(
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
        vm.skip(true);
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );

        address pool = address(0xdeadbeef);
        vm.prank(owner);
        token.lockPool(pool);
        vm.prank(recipient);
        token.approve(address(this), 1);
        // vm.expectRevert(PoolLocked.selector);
        token.transferFrom(recipient, pool, 1);
    }

    /* ----------------------------------------------------------------------------- */
    /*                                mintInflation()                                */
    /* ----------------------------------------------------------------------------- */

    function test_mintInflation_RevertsWhenMintingNotStartedYet(
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
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );
        // vm.warp(block.timestamp + 365 days);
        vm.expectRevert(MintingNotStartedYet.selector);
        token.mintInflation();
    }

    function test_mintInflation_MintsCapEveryYear(
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
        vm.assume(yearlyMintRate > 0);
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );
        vm.prank(owner);
        token.unlockPool();

        vm.warp(token.lastMintTimestamp() + 365 days);
        uint256 initialBalance = token.balanceOf(token.owner());
        uint256 totalMinted = initialSupply * yearlyMintRate / 1 ether;
        token.mintInflation();
        assertEq(token.balanceOf(token.owner()), initialBalance + totalMinted, "Wrong balance");
        assertEq(token.totalSupply(), initialSupply + totalMinted, "Wrong total supply");

        vm.warp(token.lastMintTimestamp() + 365 days);
        totalMinted += token.totalSupply() * yearlyMintRate / 1 ether;
        token.mintInflation();
        assertEq(token.balanceOf(token.owner()), initialBalance + totalMinted, "Wrong balance");
        assertEq(token.totalSupply(), initialSupply + totalMinted, "Wrong total supply");
    }

    function test_mintInflation_MintsPartialYear(
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
        yearlyMintRate = bound(yearlyMintRate, 0.005 ether, MAX_YEARLY_MINT_RATE_WAD);
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );
        vm.prank(owner);
        token.unlockPool();

        vm.warp(token.lastMintTimestamp() + 180 days);
        uint256 initialBalance = token.balanceOf(token.owner());
        uint256 expectedPartialYearMint =
            (initialSupply * yearlyMintRate * (block.timestamp - token.lastMintTimestamp())) / (1 ether * 365 days);
        token.mintInflation();
        assertEq(token.balanceOf(token.owner()), initialBalance + expectedPartialYearMint, "Wrong balance");
        assertEq(token.totalSupply(), initialSupply + expectedPartialYearMint, "Wrong total supply");
    }

    function test_mintInflation_MintsMultipleYearsAndPartialYear(
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
        vm.assume(yearlyMintRate > 0);
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );
        vm.prank(owner);
        token.unlockPool();

        vm.warp(token.lastMintTimestamp() + (365 days * 4) + 180 days);
        uint256 initialBalance = token.balanceOf(token.owner());
        uint256 expectedYearMints;
        uint256 supply = initialSupply;
        for (uint256 i = 0; i < 4; ++i) {
            uint256 yearMint = supply * yearlyMintRate / 1 ether;
            expectedYearMints += yearMint;
            supply += yearMint;
        }
        uint256 expectedNextYearMint = (supply * yearlyMintRate * 180 days) / (1 ether * 365 days);
        token.mintInflation();
        assertEq(
            token.balanceOf(token.owner()), initialBalance + expectedYearMints + expectedNextYearMint, "Wrong balance"
        );
        assertEq(token.totalSupply(), initialSupply + expectedYearMints + expectedNextYearMint, "Wrong total supply");
    }

    function test_mintInflation_RevertsWhenNoMintableAmount(
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
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );
        vm.prank(owner);
        token.unlockPool();
        vm.expectRevert(NoMintableAmount.selector);
        token.mintInflation();
    }

    /* -------------------------------------------------------------------- */
    /*                                burn()                                */
    /* -------------------------------------------------------------------- */

    function test_burn_RevertsWhenInvalidOwner(
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
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.Unauthorized.selector));
        token.burn(0);
    }

    error InsufficientBalance();

    function test_burn_RevertsWhenBurnAmountExceedsBalance(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        uint256 yearlyMintRate,
        uint256 vestingDuration,
        string memory tokenURI,
        uint256 seed
    ) public {
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, address(this), yearlyMintRate, vestingDuration, tokenURI, seed
        );
        vm.expectRevert(InsufficientBalance.selector);
        token.burn(1);
    }

    function test_burn_BurnsTokens(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 yearlyMintRate,
        uint256 vestingDuration,
        string memory tokenURI,
        uint256 seed
    ) public {
        testFuzz_initialize(
            name, symbol, initialSupply, address(this), address(this), yearlyMintRate, vestingDuration, tokenURI, seed
        );
        uint256 balanceBefore = token.balanceOf(address(this));
        token.burn(1);
        assertEq(token.balanceOf(address(this)), balanceBefore - 1, "Wrong balance after burn");
    }

    /* ------------------------------------------------------------------------------ */
    /*                                updateTokenURI()                                */
    /* ------------------------------------------------------------------------------ */

    function test_updateTokenURI_UpdatesToNewTokenURI(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        uint256 yearlyMintRate,
        uint256 vestingDuration,
        string memory tokenURI,
        uint256 seed
    ) public {
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, address(this), yearlyMintRate, vestingDuration, tokenURI, seed
        );

        token.updateTokenURI("newTokenURI");
        assertEq(token.tokenURI(), "newTokenURI", "Token URI should be updated");
    }

    function test_updateTokenURI_RevertsWhenNotOwner(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address owner,
        address recipient,
        uint256 yearlyMintRate,
        uint256 vestingDuration,
        string memory tokenURI,
        uint256 seed
    ) public {
        vm.assume(owner != address(this));
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.updateTokenURI("newTokenURI");
    }

    /* ----------------------------------------------------------------------- */
    /*                                release()                                */
    /* ----------------------------------------------------------------------- */

    function test_release_ReleasesAllTokensAfterVesting(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        uint256 yearlyMintRate,
        uint256 vestingDuration,
        string memory tokenURI,
        uint256 seed
    ) public {
        vm.assume(vestingDuration > 100 && vestingDuration < type(uint32).max);
        (, address[] memory recipients, uint256[] memory amounts) = testFuzz_initialize(
            name, symbol, initialSupply, recipient, address(this), yearlyMintRate, vestingDuration, tokenURI, seed
        );

        token.unlockPool();
        vm.warp(token.vestingStart() + vestingDuration);

        for (uint256 i; i != recipients.length; ++i) {
            uint256 availableAmount = token.computeAvailableVestedAmount(recipients[i]);
            assertEq(availableAmount, amounts[i], "Wrong available amount");
            vm.prank(recipients[i]);
            token.release();
            assertEq(token.balanceOf(recipients[i]), amounts[i], "Wrong balance");
        }
    }

    function test_release_ReleasesTokensLinearly(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        uint256 yearlyMintRate,
        uint256 vestingDuration,
        string memory tokenURI,
        uint256 seed
    ) public {
        vm.assume(vestingDuration > 100 && vestingDuration < type(uint32).max);
        (, address[] memory recipients, uint256[] memory amounts) = testFuzz_initialize(
            name, symbol, initialSupply, recipient, address(this), yearlyMintRate, vestingDuration, tokenURI, seed
        );

        token.unlockPool();
        vm.warp(token.vestingStart() + vestingDuration / 4);

        for (uint256 i; i != recipients.length; ++i) {
            uint256 balanceBefore = token.balanceOf(recipients[i]);
            uint256 availableAmount = token.computeAvailableVestedAmount(recipients[i]);
            vm.prank(recipients[i]);
            token.release();
            uint256 balanceAfter = token.balanceOf(recipients[i]);
            assertEq(balanceAfter - balanceBefore, availableAmount, "Wrong released amount");
        }

        vm.warp(token.vestingStart() + vestingDuration / 2);

        for (uint256 i; i != recipients.length; ++i) {
            uint256 balanceBefore = token.balanceOf(recipients[i]);
            uint256 availableAmount = token.computeAvailableVestedAmount(recipients[i]);
            vm.prank(recipients[i]);
            token.release();
            uint256 balanceAfter = token.balanceOf(recipients[i]);
            assertEq(balanceAfter - balanceBefore, availableAmount, "Wrong released amount");
        }

        vm.warp(token.vestingStart() + vestingDuration);

        for (uint256 i; i != recipients.length; ++i) {
            uint256 balanceBefore = token.balanceOf(recipients[i]);
            uint256 availableAmount = token.computeAvailableVestedAmount(recipients[i]);
            vm.prank(recipients[i]);
            token.release();
            uint256 balanceAfter = token.balanceOf(recipients[i]);
            assertEq(balanceAfter - balanceBefore, availableAmount, "Wrong released amount");
            assertEq(token.balanceOf(recipients[i]), amounts[i], "Wrong balance #3 release");
        }
    }
}
