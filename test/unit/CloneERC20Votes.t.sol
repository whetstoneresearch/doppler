// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { Initializable } from "solady/utils/Initializable.sol";
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
    ) public {
        vm.assume(initialSupply > MIN_INITIAL_SUPPLY);
        vm.assume(initialSupply < type(uint256).max / MAX_TOTAL_PRE_MINT_WAD);
        vm.assume(yearlyMintRate <= MAX_YEARLY_MINT_RATE_WAD);

        (uint256 totalPreMint, address[] memory recipients, uint256[] memory amounts) =
            generateRecipients(seed, initialSupply);

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

    function testFuzz_initialize_RevertsWhenMaxPreMintPerAddressExceeded(
        uint256 initialSupply
    ) public {
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

    function testFuzz_initialize_RevertsWhenMaxPreMintPerAddressExceededReusingAddress(
        uint256 initialSupply
    ) public {
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

    function testFuzz_initialize_RevertsWhenMaxTotalPreMintExceeded(
        uint256 initialSupply
    ) public {
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

    function testFuzz_lockPool(
        address pool
    ) public {
        token.initialize("", "", 0, address(0), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.lockPool(pool);
        assertEq(token.pool(), pool, "Wrong pool");
        assertEq(token.isPoolUnlocked(), false, "Pool should be locked");
    }

    function testFuzz_lockPool_RevertsWhenInvalidOwner(
        address pool
    ) public {
        token.initialize("", "", 0, address(0), address(this), 0, 0, new address[](0), new uint256[](0), "");

        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.Unauthorized.selector));
        token.lockPool(pool);
    }

    /* -------------------------------------------------------------------------- */
    /*                                unlockPool()                                */
    /* -------------------------------------------------------------------------- */

    function testFuzz_unlockPool(
        address pool
    ) public {
        testFuzz_lockPool(pool);
        token.unlockPool();
        assertEq(token.isPoolUnlocked(), true, "Pool should be unlocked");
        assertEq(token.lastMintTimestamp(), block.timestamp, "Inflation should have started");
        assertEq(token.currentYearStart(), block.timestamp, "Current year start should be the current timestamp");
    }

    function testFuzz_unlockPool_RevertsWhenInvalidOwner(
        address pool
    ) public {
        testFuzz_lockPool(pool);
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.Unauthorized.selector));
        token.unlockPool();
    }

    /* ------------------------------------------------------------------------ */
    /*                                transfer()                                */
    /* ------------------------------------------------------------------------ */

    function test_transfer_RevertsWhenPoolLocked(
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

        address pool = address(0xdeadbeef);
        token.lockPool(pool);
        vm.expectRevert(PoolLocked.selector);
        token.transfer(pool, 1);
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
        testFuzz_initialize(
            name, symbol, initialSupply, recipient, owner, yearlyMintRate, vestingDuration, tokenURI, seed
        );

        address pool = address(0xdeadbeef);
        token.lockPool(pool);
        vm.expectRevert(PoolLocked.selector);
        token.transferFrom(address(this), pool, 1);
    }

    /*
    function test_mintInflation_RevertsWhenMintingNotStartedYet() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(MintingNotStartedYet.selector);
        token.mintInflation();
    }

    function test_mintInflation_MintsCapEveryYear() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );
        token.unlockPool();

        vm.warp(token.lastMintTimestamp() + 365 days);
        uint256 initialBalance = token.balanceOf(token.owner());
        uint256 totalMinted = INITIAL_SUPPLY * YEARLY_MINT_RATE / 1 ether;
        token.mintInflation();
        assertEq(token.balanceOf(token.owner()), initialBalance + totalMinted, "Wrong balance");
        assertEq(token.totalSupply(), INITIAL_SUPPLY + totalMinted, "Wrong total supply");

        vm.warp(token.lastMintTimestamp() + 365 days);
        totalMinted += token.totalSupply() * YEARLY_MINT_RATE / 1 ether;
        token.mintInflation();
        assertEq(token.balanceOf(token.owner()), initialBalance + totalMinted, "Wrong balance");
        assertEq(token.totalSupply(), INITIAL_SUPPLY + totalMinted, "Wrong total supply");
    }

    function test_mintInflation_MintsPartialYear() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );
        token.unlockPool();

        vm.warp(token.lastMintTimestamp() + 180 days);
        uint256 initialBalance = token.balanceOf(token.owner());
        uint256 expectedPartialYearMint =
            (INITIAL_SUPPLY * YEARLY_MINT_RATE * (block.timestamp - token.lastMintTimestamp())) / (1 ether * 365 days);
        token.mintInflation();
        assertEq(token.balanceOf(token.owner()), initialBalance + expectedPartialYearMint, "Wrong balance");
        assertEq(token.totalSupply(), INITIAL_SUPPLY + expectedPartialYearMint, "Wrong total supply");
    }

    function test_mintInflation_MintsMultipleYearsAndPartialYear() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );
        token.unlockPool();

        vm.warp(token.lastMintTimestamp() + (365 days * 4) + 180 days);
        uint256 initialBalance = token.balanceOf(token.owner());
        uint256 expectedYearMints;
        uint256 supply = INITIAL_SUPPLY;
        for (uint256 i = 0; i < 4; ++i) {
            uint256 yearMint = supply * YEARLY_MINT_RATE / 1 ether;
            expectedYearMints += yearMint;
            supply += yearMint;
        }
        uint256 expectedNextYearMint = (supply * YEARLY_MINT_RATE * 180 days) / (1 ether * 365 days);
        token.mintInflation();
        assertEq(
            token.balanceOf(token.owner()), initialBalance + expectedYearMints + expectedNextYearMint, "Wrong balance"
        );
        assertEq(token.totalSupply(), INITIAL_SUPPLY + expectedYearMints + expectedNextYearMint, "Wrong total supply");
    }

    function test_mintInflation_RevertsWhenNoMintableAmount() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );
        token.unlockPool();
        vm.expectRevert(NoMintableAmount.selector);
        token.mintInflation();
    }

    function test_mintInflation_MintsAfterDelayedPoolUnlock() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );

        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(MintingNotStartedYet.selector);
        token.mintInflation();

        vm.warp(block.timestamp + 2 * 365 days);
        token.unlockPool();

        vm.warp(token.lastMintTimestamp() + 365 days);
        token.mintInflation();
        uint256 expectedMint = INITIAL_SUPPLY * YEARLY_MINT_RATE / 1 ether;
        assertEq(token.balanceOf(token.owner()), expectedMint, "Wrong balance");
        assertEq(token.totalSupply(), INITIAL_SUPPLY + expectedMint, "Wrong total supply");
    }

    function test_burn_RevertsWhenInvalidOwner() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xbeef)));
        token.burn(0);
    }

    function test_burn_RevertsWhenBurnAmountExceedsBalance() public {
        address pool = address(0xdeadbeef);
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );
        token.lockPool(pool);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.burn(1);
    }

    function test_burn_BurnsTokens() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );
        token.unlockPool();
        vm.warp(token.lastMintTimestamp() + 365 days);
        token.mintInflation();

        uint256 expectedYearMint = INITIAL_SUPPLY * YEARLY_MINT_RATE / 1 ether;
        assertEq(token.totalSupply(), INITIAL_SUPPLY + expectedYearMint, "Wrong total supply");
        assertEq(token.balanceOf(token.owner()), expectedYearMint, "Wrong balance");
        token.burn(expectedYearMint);
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "Wrong total supply");
        assertEq(token.balanceOf(token.owner()), 0, "Wrong balance");

        vm.warp(token.lastMintTimestamp() + 1 days);
        token.mintInflation();
        assertGt(token.totalSupply(), INITIAL_SUPPLY, "Total supply should be greater than initial supply");
        assertGt(token.balanceOf(token.owner()), 0, "Owner balance should be greater than 0");
    }

    function test_updateTokenURI_UpdatesToNewTokenURI() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );

        assertEq(token.tokenURI(), "", "Token URI should be empty");
        token.updateTokenURI("newTokenURI");
        assertEq(token.tokenURI(), "newTokenURI", "Token URI should be updated");
    }

    function test_updateTokenURI_RevertsWhenNotOwner() public {
        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(0xbeef),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            ""
        );

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.updateTokenURI("newTokenURI");
    }

    function test_release_ReleasesAllTokensAfterVesting() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xa);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e23;

        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            recipients,
            amounts,
            ""
        );

        token.unlockPool();
        assertEq(token.vestingStart(), block.timestamp, "Wrong vesting start");

        vm.warp(token.vestingStart() + VESTING_DURATION);
        vm.prank(address(0xa));
        token.release();
        assertEq(token.balanceOf(address(0xa)), amounts[0], "Wrong balance");
    }

    function test_release_ReleasesTokensLinearly() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xa);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e23;

        token = new DERC20(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            RECIPIENT,
            address(this),
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            recipients,
            amounts,
            ""
        );

        token.unlockPool();
        assertEq(token.vestingStart(), block.timestamp, "Wrong vesting start");

        vm.startPrank(address(0xa));
        vm.warp(token.vestingStart() + VESTING_DURATION / 4);
        token.release();
        assertEq(token.balanceOf(address(0xa)), amounts[0] / 4, "Wrong balance");

        vm.warp(token.vestingStart() + VESTING_DURATION / 2);
        token.release();
    }
    */
}
