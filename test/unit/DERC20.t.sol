/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import {
    DERC20,
    ArrayLengthsMismatch,
    MaxPreMintPerAddressExceeded,
    MaxTotalPreMintExceeded,
    MAX_PRE_MINT_PER_ADDRESS_WAD,
    MAX_TOTAL_PRE_MINT_WAD
} from "src/DERC20.sol";

uint256 constant INITIAL_SUPPLY = 1e26;
uint256 constant YEARLY_MINT_CAP = 1e25;
uint256 constant VESTING_DURATION = 365 days;
string constant NAME = "Test";
string constant SYMBOL = "TST";
address constant RECIPIENT = address(0xa71ce);
address constant OWNER = address(0xb0b);

contract DERC20Test is Test {
    DERC20 public token;

    function test_constructor() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xa);
        recipients[1] = address(0xb);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e23;
        amounts[1] = 2e23;

        token = new DERC20(
            NAME, SYMBOL, INITIAL_SUPPLY, RECIPIENT, OWNER, YEARLY_MINT_CAP, VESTING_DURATION, recipients, amounts
        );

        assertEq(token.name(), NAME, "Wrong name");
        assertEq(token.symbol(), SYMBOL, "Wrong symbol");
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "Wrong total supply");
        assertEq(token.balanceOf(RECIPIENT), INITIAL_SUPPLY - amounts[0] - amounts[1], "Wrong balance of recipient");
        assertEq(token.balanceOf(address(token)), amounts[0] + amounts[1], "Wrong balance of vested tokens");
        assertEq(token.mintStartDate(), block.timestamp + 365 days, "Wrong mint start date");
        assertEq(token.owner(), OWNER, "Wrong owner");
        assertEq(token.yearlyMintCap(), YEARLY_MINT_CAP, "Wrong yearly mint cap");
        assertEq(token.vestingStart(), block.timestamp, "Wrong vesting start");
        assertEq(token.vestingDuration(), VESTING_DURATION, "Wrong vesting duration");
    }

    function test_constructor_RevertsWhenArrayLengthsMismatch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xa);
        recipients[1] = address(0xb);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e23;

        vm.expectRevert(ArrayLengthsMismatch.selector);
        token = new DERC20(
            NAME, SYMBOL, INITIAL_SUPPLY, RECIPIENT, OWNER, YEARLY_MINT_CAP, VESTING_DURATION, recipients, amounts
        );
    }

    function test_constructor_RevertsWhenMaxPreMintPerAddressExceeded() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xa);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18 + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                MaxPreMintPerAddressExceeded.selector, amounts[0], INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18
            )
        );
        token = new DERC20(
            NAME, SYMBOL, INITIAL_SUPPLY, RECIPIENT, OWNER, YEARLY_MINT_CAP, VESTING_DURATION, recipients, amounts
        );
    }

    function test_constructor_RevertsWhenMaxPreMintPerAddressExceededReusingAddress() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xa);
        recipients[1] = address(0xa);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        amounts[1] = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;

        vm.expectRevert(abi.encodeWithSelector(MaxPreMintPerAddressExceeded.selector, amounts[0] * 2, amounts[0]));
        token = new DERC20(
            NAME, SYMBOL, INITIAL_SUPPLY, RECIPIENT, OWNER, YEARLY_MINT_CAP, VESTING_DURATION, recipients, amounts
        );
    }

    function test_constructor_RevertsWhenMaxTotalPreMintExceeded() public {
        uint256 maxTotalPreMint = INITIAL_SUPPLY * MAX_TOTAL_PRE_MINT_WAD / 1 ether;
        uint256 length = MAX_TOTAL_PRE_MINT_WAD / MAX_PRE_MINT_PER_ADDRESS_WAD + 1;

        address[] memory recipients = new address[](length);
        uint256[] memory amounts = new uint256[](length);

        for (uint256 i; i != length; ++i) {
            recipients[i] = address(uint160(i));
            amounts[i] = INITIAL_SUPPLY * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18;
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                MaxTotalPreMintExceeded.selector, maxTotalPreMint * 1.1 ether / 1e18, maxTotalPreMint
            )
        );
        token = new DERC20(
            NAME, SYMBOL, INITIAL_SUPPLY, RECIPIENT, OWNER, YEARLY_MINT_CAP, VESTING_DURATION, recipients, amounts
        );
    }
}
