// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import {
    InvalidSplitRecipient,
    MAX_SPLIT_SHARE,
    ProceedsSplitter,
    SplitConfiguration,
    SplitShareTooHigh
} from "src/base/ProceedsSplitter.sol";
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
            SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18, donated: 0 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (address storedRecipient, bool storedIsToken0, uint256 storedShare, uint256 storedDonated) =
            proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedRecipient, recipient);
        assertTrue(storedIsToken0);
        assertEq(storedShare, 0.25e18);
    }

    function test_setSplit_withToken0() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.3e18, donated: 0 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (address storedRecipient, bool storedIsToken0, uint256 storedShare, uint256 storedDonated) =
            proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedRecipient, recipient);
        assertTrue(storedIsToken0);
        assertEq(storedShare, 0.3e18);
    }

    function test_setSplit_withToken1() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: false, share: 0.2e18, donated: 0 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (address storedRecipient, bool storedIsToken0, uint256 storedShare, uint256 storedDonated) =
            proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedRecipient, recipient);
        assertFalse(storedIsToken0);
        assertEq(storedShare, 0.2e18);
    }

    function test_setSplit_atMaxShare() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: MAX_SPLIT_SHARE, donated: 0 });

        proceedsSplitter.setSplit(address(token0), address(token1), config);

        (,, uint256 storedShare,) = proceedsSplitter.splitConfigurationOf(address(token0), address(token1));

        assertEq(storedShare, MAX_SPLIT_SHARE);
    }

    function test_setSplit_revertsOnZeroRecipient() public {
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: address(0), isToken0: true, share: 0.25e18, donated: 0 });

        vm.expectRevert(InvalidSplitRecipient.selector);
        proceedsSplitter.setSplit(address(token0), address(token1), config);
    }

    function test_setSplit_revertsOnShareTooHigh() public {
        uint256 tooHighShare = MAX_SPLIT_SHARE + 1;
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: tooHighShare, donated: 0 });

        vm.expectRevert(abi.encodeWithSelector(SplitShareTooHigh.selector, tooHighShare, MAX_SPLIT_SHARE));
        proceedsSplitter.setSplit(address(token0), address(token1), config);
    }

    function testFuzz_setSplit_revertsOnShareTooHigh(uint256 share) public {
        vm.assume(share > MAX_SPLIT_SHARE);
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: share, donated: 0 });

        vm.expectRevert(abi.encodeWithSelector(SplitShareTooHigh.selector, share, MAX_SPLIT_SHARE));
        proceedsSplitter.setSplit(address(token0), address(token1), config);
    }

    /* ------------------------------------------------------------------------------- */
    /*                                distributeSplit()                                */
    /* ------------------------------------------------------------------------------- */

    function test_distributeSplit_withToken0Split() public {
        // Setup: 25% of numeraire (token1) goes to recipient when asset is token0
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18, donated: 0 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        // Give tokens to the splitter
        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance1 * 0.25e18 / WAD; // 500e18 (25% of numeraire)
        uint256 expectedBalanceLeft1 = balance1 - expectedSplit; // 1500e18

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(token0), address(token1), recipient, expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0); // token0 balance unchanged
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }

    function test_distributeSplit_withToken1Split() public {
        // Setup: 30% of numeraire (token0) goes to recipient when asset is token1
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: false, share: 0.3e18, donated: 0 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        // Give tokens to the splitter
        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * 0.3e18 / WAD; // 300e18 (30% of numeraire)
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit; // 700e18

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(token0), address(token1), recipient, expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1); // token1 balance unchanged
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
        // Setup: 25% split but numeraire balance is 0, so no split occurs
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: 0.25e18, donated: 0 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        uint256 balance0 = 1000e18;
        uint256 balance1 = 0; // Numeraire is zero, so split amount will be 0

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        // Should return original balances since split amount is 0
        assertEq(balanceLeft0, balance0);
        assertEq(balanceLeft1, balance1);
    }

    function test_distributeSplit_withETH() public {
        // Setup: 20% of ETH (numeraire) goes to recipient when asset is token0
        // Note: address(0) < address(token0), so token0=address(0), token1=address(token0)
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: address(ethReceiver), isToken0: false, share: 0.2e18, donated: 0 });
        proceedsSplitter.setSplit(address(0), address(token0), config);

        // Give tokens to the splitter
        // Split amount will be balance0 (ETH) * 0.2 = 250e18 * 0.2 = 50e18
        uint256 balance0 = 250 ether; // ETH (numeraire)
        uint256 balance1 = 1000e18; // token0 (asset)
        vm.deal(address(proceedsSplitter), balance0);
        token0.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * 0.2e18 / WAD; // 50e18
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit; // 200e18
        uint256 recipientBalanceBefore = address(ethReceiver).balance;

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(0), address(token0), address(ethReceiver), expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(0), address(token0), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1); // token0 balance unchanged
        assertEq(address(ethReceiver).balance, recipientBalanceBefore + expectedSplit);
    }

    function test_distributeSplit_withETHAsNumeraire() public {
        // Setup: 15% of ETH (numeraire) split, when asset is token1
        // token0 is address(0)=ETH, token1 is ERC20
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: address(ethReceiver), isToken0: false, share: 0.15e18, donated: 0 });
        proceedsSplitter.setSplit(address(0), address(token1), config);

        // Give tokens to the splitter
        // Split amount will be balance0 (ETH) * 0.15 = 200e18 * 0.15 = 30e18
        uint256 balance0 = 200 ether; // ETH (numeraire)
        uint256 balance1 = 1000e18; // ERC20 (asset)
        vm.deal(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance0 * 0.15e18 / WAD; // 30e18 (15% of numeraire)
        uint256 expectedBalanceLeft0 = balance0 - expectedSplit; // 170e18
        uint256 recipientBalanceBefore = address(ethReceiver).balance;

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit DistributeSplit(address(0), address(token1), address(ethReceiver), expectedSplit);

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1); // ERC20 balance unchanged
        assertEq(address(ethReceiver).balance, recipientBalanceBefore + expectedSplit);
    }

    function testFuzz_distributeSplit_withToken0Split(uint256 balance0, uint256 balance1, uint256 share) public {
        vm.assume(balance1 > 0 && balance1 < type(uint128).max);
        vm.assume(share > 0 && share <= MAX_SPLIT_SHARE);

        // Calculate expected split amount from numeraire (token1) when asset is token0
        uint256 expectedSplit = balance1 * share / WAD;
        vm.assume(expectedSplit > 0);

        // Ensure we have enough balance for the split
        vm.assume(balance0 < type(uint128).max);

        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: share, donated: 0 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedBalanceLeft1 = balance1 - expectedSplit;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0); // token0 unchanged
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }

    function testFuzz_distributeSplit_withToken1Split(uint256 balance0, uint256 balance1, uint256 share) public {
        vm.assume(balance0 > 0 && balance0 < type(uint128).max);
        vm.assume(share > 0 && share <= MAX_SPLIT_SHARE);

        // Calculate expected split amount from numeraire (token0) when asset is token1
        uint256 expectedSplit = balance0 * share / WAD;
        vm.assume(expectedSplit > 0);

        // Ensure we have enough balance for the split
        vm.assume(balance1 < type(uint128).max);

        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: false, share: share, donated: 0 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedBalanceLeft0 = balance0 - expectedSplit;

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, expectedBalanceLeft0);
        assertEq(balanceLeft1, balance1); // token1 unchanged
        assertEq(token0.balanceOf(recipient), expectedSplit);
    }

    function test_distributeSplit_maxShare() public {
        // Setup: 50% split (max) of numeraire (token1) when asset is token0
        SplitConfiguration memory config =
            SplitConfiguration({ recipient: recipient, isToken0: true, share: MAX_SPLIT_SHARE, donated: 0 });
        proceedsSplitter.setSplit(address(token0), address(token1), config);

        uint256 balance0 = 1000e18;
        uint256 balance1 = 2000e18;
        token0.mint(address(proceedsSplitter), balance0);
        token1.mint(address(proceedsSplitter), balance1);

        uint256 expectedSplit = balance1 * MAX_SPLIT_SHARE / WAD; // 1000e18 (50% of numeraire)
        uint256 expectedBalanceLeft1 = balance1 - expectedSplit; // 1000e18

        (uint256 balanceLeft0, uint256 balanceLeft1) =
            proceedsSplitter.distributeSplit(address(token0), address(token1), balance0, balance1);

        assertEq(balanceLeft0, balance0); // token0 unchanged
        assertEq(balanceLeft1, expectedBalanceLeft1);
        assertEq(token1.balanceOf(recipient), expectedSplit);
    }
}
