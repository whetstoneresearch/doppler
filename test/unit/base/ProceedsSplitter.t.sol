// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Test } from "forge-std/Test.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import {
    DistributeSplit,
    InvalidSplitRecipient,
    MAX_SPLIT_SHARE,
    ProceedsSplitter,
    SplitConfiguration,
    SplitShareTooHigh
} from "src/base/ProceedsSplitter.sol";
import { WAD } from "src/types/Wad.sol";

contract ProceedsSplitterImplementation is ProceedsSplitter {
    constructor(TopUpDistributor topUpDistributor) ProceedsSplitter(topUpDistributor) { }

    function setSplit(address token0, address token1, SplitConfiguration memory config) external {
        _setSplit(token0, token1, config);
    }

    function distributeSplit(
        address token0,
        address token1,
        uint256 balance0,
        uint256 balance1
    ) external payable returns (uint256 balanceLeft0, uint256 balanceLeft1) {
        return _distributeSplit(token0, token1, balance0, balance1);
    }

    receive() external payable { }
}

contract ProceedsSplitterTest is Test {
    ProceedsSplitterImplementation proceedsSplitter;
    TopUpDistributor topUpDistributor;
    TestERC20 token0;
    TestERC20 token1;
    address recipient = makeAddr("recipient");
    address ethRecipient = makeAddr("ethRecipient");

    function owner() public view returns (address) {
        return address(this);
    }

    function setUp() public {
        topUpDistributor = new TopUpDistributor(address(this));
        proceedsSplitter = new ProceedsSplitterImplementation(topUpDistributor);
        topUpDistributor.setPullUp(address(proceedsSplitter), true);
        token0 = new TestERC20(type(uint256).max);
        token1 = new TestERC20(type(uint256).max);
    }

    /* ------------------------------------------------------------------------ */
    /*                                setSplit()                                */
    /* ------------------------------------------------------------------------ */

    function test_setSplit_validConfiguration() public {
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (address storedRecipient, bool storedIsToken0, uint256 storedShare) =
            proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedRecipient, recipient);
        assertTrue(storedIsToken0);
        assertEq(storedShare, 0.25e18);
    }

    function test_setSplit_withToken0() public {
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.3e18 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (address storedRecipient, bool storedIsToken0, uint256 storedShare) =
            proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedRecipient, recipient);
        assertTrue(storedIsToken0);
        assertEq(storedShare, 0.3e18);
    }

    function test_setSplit_withToken1() public {
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: false, share: 0.2e18 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (address storedRecipient, bool storedIsToken0, uint256 storedShare) =
            proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedRecipient, recipient);
        assertFalse(storedIsToken0);
        assertEq(storedShare, 0.2e18);
    }

    function test_setSplit_atMaxShare() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: MAX_SPLIT_SHARE });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (,, uint256 storedShare) = proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedShare, MAX_SPLIT_SHARE);
    }

    function test_setSplit_revertsOnZeroRecipient() public {
        SplitConfiguration memory config = SplitConfiguration({ recipient: address(0), isToken0: true, share: 0.25e18 });

        vm.expectRevert(InvalidSplitRecipient.selector);
        proceedsSplitter.setSplit(address(token0), address(token1), config);
    }

    function test_setSplit_revertsOnShareTooHigh() public {
        uint256 tooHighShare = MAX_SPLIT_SHARE + 1;
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: tooHighShare });

        vm.expectRevert(abi.encodeWithSelector(SplitShareTooHigh.selector, tooHighShare, MAX_SPLIT_SHARE));
        proceedsSplitter.setSplit(address(token0), address(token1), config);
    }

    function testFuzz_setSplit_revertsOnShareTooHigh(uint256 share) public {
        vm.assume(share > MAX_SPLIT_SHARE);
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: share });

        vm.expectRevert(abi.encodeWithSelector(SplitShareTooHigh.selector, share, MAX_SPLIT_SHARE));
        proceedsSplitter.setSplit(address(token0), address(token1), config);
    }

    /* ------------------------------------------------------------------------------- */
    /*                                distributeSplit()                                */
    /* ------------------------------------------------------------------------------- */

    function test_distributeSplit_withToken0Split() public {
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance1 * 0.25e18 / WAD;
        uint256 expectedBalanceLeft1 = balance1 - expectedSplit;

        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(token0), address(token1), recipient, expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }

    function test_distributeSplit_withToken1Split() public {
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: false, share: 0.3e18 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * 0.3e18 / WAD;
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit;

        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(token0), address(token1), recipient, expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1);
        assertEq(token0.balanceOf(recipient), expectedSplit);
    }

    function test_distributeSplit_noConfiguration() public {
        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, balance1);
    }

    function test_distributeSplit_zeroSplitAmount() public {
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        uint256 balance0 = 1000e18;
        uint256 balance1 = 0;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, balance1);
    }

    function test_distributeSplit_withETH() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: ethRecipient, isToken0: false, share: 0.2e18 });
        proceedsSplitter.setSplit(address(0), address(token0), config);

        uint256 balance0 = 250 ether;
        uint256 balance1 = 1000e18;
        vm.deal(address(proceedsSplitter), balance0);
        token0.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * 0.2e18 / WAD;
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit;
        uint256 recipientBalanceBefore = ethRecipient.balance;

        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(0), address(token0), ethRecipient, expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(0), address(token0), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1);
        assertEq(ethRecipient.balance, recipientBalanceBefore + expectedSplit);
    }

    function test_distributeSplit_withETHAsNumeraire() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: ethRecipient, isToken0: false, share: 0.15e18 });
        proceedsSplitter.setSplit(address(0), address(token1), config);

        uint256 balance0 = 200 ether;
        uint256 balance1 = 1000e18;
        vm.deal(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * 0.15e18 / WAD;
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit;
        uint256 recipientBalanceBefore = ethRecipient.balance;

        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(0), address(token1), ethRecipient, expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1);
        assertEq(ethRecipient.balance, recipientBalanceBefore + expectedSplit);
    }

    function testFuzz_distributeSplit_withToken0Split(uint256 balance0, uint256 balance1, uint256 share) public {
        vm.assume(balance1 > 0 && balance1 < type(uint128).max);
        vm.assume(share > 0 && share <= MAX_SPLIT_SHARE);

        uint256 expectedSplit = balance1 * share / WAD;
        vm.assume(expectedSplit > 0);
        vm.assume(balance0 < type(uint128).max);

        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: share });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedBalanceLeft1 = balance1 - expectedSplit;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }

    function testFuzz_distributeSplit_withToken1Split(uint256 balance0, uint256 balance1, uint256 share) public {
        vm.assume(balance0 > 0 && balance0 < type(uint128).max);
        vm.assume(share > 0 && share <= MAX_SPLIT_SHARE);

        uint256 expectedSplit = balance0 * share / WAD;
        vm.assume(expectedSplit > 0);
        vm.assume(balance1 < type(uint128).max);

        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: false, share: share });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedBalanceLeft0 = balance0 - expectedSplit;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1);
        assertEq(token0.balanceOf(recipient), expectedSplit);
    }

    function test_distributeSplit_maxShare() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: MAX_SPLIT_SHARE });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance1 * MAX_SPLIT_SHARE / WAD;
        uint256 expectedBalanceLeft1 = balance1 - expectedSplit;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }

    /* ------------------------------------------------------------------------------- */
    /*                                constructor()                                    */
    /* ------------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(proceedsSplitter.TOP_UP_DISTRIBUTOR()), address(topUpDistributor));
    }

    /* ------------------------------------------------------------------------------- */
    /*                    distributeSplit() with TopUp integration                      */
    /* ------------------------------------------------------------------------------- */

    function test_distributeSplit_pullsUpTopUps_ERC20() public {
        // Sort addresses to match production usage (migrators always pass sorted pairs)
        (address sorted0, address sorted1) =
            address(token0) < address(token1) ? (address(token0), address(token1)) : (address(token1), address(token0));
        TestERC20 asset = TestERC20(sorted0);
        TestERC20 numeraire = TestERC20(sorted1);

        // Set up a split: asset is sorted0 (isToken0=true), numeraire is sorted1
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18 });
        proceedsSplitter.setSplit(sorted0, sorted1, config);

        // Top up 50e18 of numeraire for this pair
        uint256 topUpAmount = 50e18;
        numeraire.approve(address(topUpDistributor), topUpAmount);
        topUpDistributor.topUp(sorted0, sorted1, topUpAmount);

        // Fund the splitter with balances for migration
        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        asset.mint(address(proceedsSplitter), balance0);
        numeraire.mint(address(proceedsSplitter), balance1);

        uint256 recipientBalanceBefore = numeraire.balanceOf(recipient);

        proceedsSplitter.distributeSplit(sorted0, sorted1, balance0, balance1);

        uint256 expectedSplit = balance1 * 0.25e18 / WAD;
        // Recipient gets both the top-up AND the split
        assertEq(numeraire.balanceOf(recipient), recipientBalanceBefore + topUpAmount + expectedSplit);

        // TopUp amount is cleared
        (uint256 remaining,) = topUpDistributor.topUpOf(sorted0, sorted1);
        assertEq(remaining, 0);
    }

    function test_distributeSplit_pullsUpTopUps_ETH() public {
        // Set up a split: asset is token1 (isToken0=false), numeraire is ETH (token0=address(0))
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: ethRecipient, isToken0: false, share: 0.2e18 });
        proceedsSplitter.setSplit(address(0), address(token0), config);

        // Top up 5 ETH
        uint256 topUpAmount = 5 ether;
        vm.deal(address(this), topUpAmount);
        topUpDistributor.topUp{ value: topUpAmount }(address(token0), address(0), topUpAmount);

        // Fund the splitter
        uint256 balance0 = 100 ether;
        uint256 balance1 = 1000e18;
        vm.deal(address(proceedsSplitter), balance0);
        token0.mint(address(proceedsSplitter), balance1);

        uint256 recipientBalanceBefore = ethRecipient.balance;

        proceedsSplitter.distributeSplit(address(0), address(token0), balance0, balance1);

        uint256 expectedSplit = balance0 * 0.2e18 / WAD;
        // Recipient gets both the ETH top-up AND the ETH split
        assertEq(ethRecipient.balance, recipientBalanceBefore + topUpAmount + expectedSplit);
    }

    function test_distributeSplit_pullsUpTopUps_evenWhenSplitIsZero() public {
        // Sort addresses to match production usage
        (address sorted0, address sorted1) =
            address(token0) < address(token1) ? (address(token0), address(token1)) : (address(token1), address(token0));
        TestERC20 numeraire = TestERC20(sorted1);

        // Set up a split with share that rounds to 0 for the given balance
        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: 1 }); // tiny share
        proceedsSplitter.setSplit(sorted0, sorted1, config);

        // Top up 50e18 of numeraire
        uint256 topUpAmount = 50e18;
        numeraire.approve(address(topUpDistributor), topUpAmount);
        topUpDistributor.topUp(sorted0, sorted1, topUpAmount);

        // balance1 * 1 / WAD = 0 due to rounding
        uint256 balance0 = 1000e18;
        uint256 balance1 = 1; // small enough that split rounds to 0
        TestERC20(sorted0).mint(address(proceedsSplitter), balance0);
        numeraire.mint(address(proceedsSplitter), balance1);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(sorted0, sorted1, balance0, balance1);

        // Balances unchanged (split was 0, early return)
        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, balance1);

        // But top-ups were still pulled and delivered
        assertEq(numeraire.balanceOf(recipient), topUpAmount);
        (uint256 remaining,) = topUpDistributor.topUpOf(sorted0, sorted1);
        assertEq(remaining, 0);
    }
}
