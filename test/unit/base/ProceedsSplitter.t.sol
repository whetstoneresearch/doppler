// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import {
    MAX_SPLIT_SHARE,
    ProceedsSplitter,
    SplitConfiguration,
    InvalidSplitRecipient,
    SplitShareTooHigh
} from "src/base/ProceedsSplitter.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { WAD } from "src/types/WAD.sol";

// Mock ERC20 token for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ProceedsSplitterImplementation is ProceedsSplitter {
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

// Helper contract that can receive ETH
contract ETHReceiver {
    receive() external payable { }
}

contract ProceedsSplitterTest is Test {
    ProceedsSplitterImplementation proceedsSplitter;
    MockERC20 token0;
    MockERC20 token1;
    address recipient;
    ETHReceiver ethReceiver;

    event DistributeSplit(address indexed token0, address indexed token1, address indexed recipient, uint256 amount);

    function setUp() public {
        proceedsSplitter = new ProceedsSplitterImplementation();
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        recipient = makeAddr("recipient");
        ethReceiver = new ETHReceiver();
    }

    /* ------------------------------------------------------------------------ */
    /*                                setSplit()                                */
    /* ------------------------------------------------------------------------ */

    function test_setSplit_validConfiguration() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (address storedRecipient, bool storedIsToken0, uint256 storedShare) =
            proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedRecipient, recipient);
        assertTrue(storedIsToken0);
        assertEq(storedShare, 0.25e18);
    }

    function test_setSplit_withToken0() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.3e18 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (address storedRecipient, bool storedIsToken0, uint256 storedShare) =
            proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedRecipient, recipient);
        assertTrue(storedIsToken0);
        assertEq(storedShare, 0.3e18);
    }

    function test_setSplit_withToken1() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: false, share: 0.2e18 });

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
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: address(0), isToken0: true, share: 0.25e18 });

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
        // Setup: 25% of token0 goes to recipient
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        // Give tokens to the splitter
        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * 0.25e18 / WAD; // 250e18
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit; // 750e18

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(token0), address(token1), recipient, expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1); // token1 balance unchanged
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }

    function test_distributeSplit_withToken1Split() public {
        // Setup: 30% of token1 goes to recipient
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: false, share: 0.3e18 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        // Give tokens to the splitter
        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance1 * 0.3e18 / WAD; // 600e18
        uint256 expectedBalanceLeft1 = balance1 - expectedSplit; // 1400e18

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(token0), address(token1), recipient, expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0); // token0 balance unchanged
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(token0.balanceOf(recipient), expectedSplit);
    }

    function test_distributeSplit_noConfiguration() public {
        // No split configuration set
        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        // Should return original balances
        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, balance1);
    }

    function test_distributeSplit_zeroSplitAmount() public {
        // Setup: 25% split but balance is 0
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        uint256 balance0 = 0;
        uint256 balance1 = 2000e18;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        // Should return original balances
        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, balance1);
    }

    function test_distributeSplit_withETH() public {
        // Setup: 20% of token0 (asset) goes to recipient, token1 is ETH (address(0))
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: address(ethReceiver), isToken0: true, share: 0.2e18 });
        proceedsSplitter.setSplit(address(token0), address(0), config);

        // Give tokens to the splitter
        // Split amount will be balance0 * 0.2 = 1000e18 * 0.2 = 200e18
        // So we need at least 200e18 ETH for the transfer
        uint256 balance0 = 1000e18;
        uint256 balance1 = 250 ether; // More than enough for the 200e18 split
        token0.mint(address(proceedsSplitter), balance0);
        vm.deal(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * 0.2e18 / WAD; // 200e18
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit; // 800e18
        uint256 recipientBalanceBefore = address(ethReceiver).balance;

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(token0), address(0), address(ethReceiver), expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(0), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1); // ETH balance unchanged
        assertEq(address(ethReceiver).balance, recipientBalanceBefore + expectedSplit);
    }

    function test_distributeSplit_withETHAsNumeraire() public {
        // Setup: 15% of token1 split, paid in ETH (numeraire), token0 is address(0)
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: address(ethReceiver), isToken0: false, share: 0.15e18 });
        proceedsSplitter.setSplit(address(0), address(token1), config);

        // Give tokens to the splitter
        // Split amount will be balance1 * 0.15 = 1000e18 * 0.15 = 150e18
        // So we need at least 150e18 ETH for the transfer
        uint256 balance0 = 200 ether; // More than enough for the 150e18 split
        uint256 balance1 = 1000e18;
        vm.deal(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance1 * 0.15e18 / WAD; // 150e18
        uint256 expectedBalanceLeft1 = balance1 - expectedSplit; // 850e18
        uint256 recipientBalanceBefore = address(ethReceiver).balance;

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(0), address(token1), address(ethReceiver), expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0); // ETH balance unchanged
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(address(ethReceiver).balance, recipientBalanceBefore + expectedSplit);
    }

    function testFuzz_distributeSplit_withToken0Split(uint256 balance0, uint256 balance1, uint256 share) public {
        vm.assume(balance0 > 0 && balance0 < type(uint128).max);
        vm.assume(share > 0 && share <= MAX_SPLIT_SHARE);

        // Calculate expected split amount
        uint256 expectedSplit = balance0 * share / WAD;
        vm.assume(expectedSplit > 0);

        // Ensure numeraire (token1) has enough balance for the split
        vm.assume(balance1 >= expectedSplit && balance1 < type(uint128).max);

        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: true, share: share });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedBalanceLeft0 = balance0 - expectedSplit;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1);
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }

    function testFuzz_distributeSplit_withToken1Split(uint256 balance0, uint256 balance1, uint256 share) public {
        vm.assume(balance1 > 0 && balance1 < type(uint128).max);
        vm.assume(share > 0 && share <= MAX_SPLIT_SHARE);

        // Calculate expected split amount
        uint256 expectedSplit = balance1 * share / WAD;
        vm.assume(expectedSplit > 0);

        // Ensure numeraire (token0) has enough balance for the split
        vm.assume(balance0 >= expectedSplit && balance0 < type(uint128).max);

        SplitConfiguration memory config = SplitConfiguration({ recipient: recipient, isToken0: false, share: share });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedBalanceLeft1 = balance1 - expectedSplit;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(token0.balanceOf(recipient), expectedSplit);
    }

    function test_distributeSplit_maxShare() public {
        // Setup: 50% split (max)
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: MAX_SPLIT_SHARE });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * MAX_SPLIT_SHARE / WAD; // 500e18
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit; // 500e18

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1);
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }
}
