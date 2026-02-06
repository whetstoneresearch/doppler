// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Airlock } from "src/Airlock.sol";
import {
    InvalidETHAmount,
    PullUp,
    SenderCannotPullUp,
    SenderNotAirlockOwner,
    TopUp,
    TopUpDistributor
} from "src/TopUpDistributor.sol";

contract TopUpDistributorTest is Test {
    address public airlockOwner = makeAddr("AirlockOwner");
    address public migrator = makeAddr("Migrator");
    address public recipient = makeAddr("Recipient");
    address public asset;
    address public numeraire;

    Airlock public airlock;
    TopUpDistributor public distributor;
    TestERC20 public token;

    function setUp() public {
        airlock = new Airlock(airlockOwner);
        distributor = new TopUpDistributor(address(airlock));
        token = new TestERC20(type(uint256).max);

        // Set up sorted addresses for native ETH tests: asset > address(0) always
        asset = address(token);
        numeraire = address(0); // native ETH
    }

    /* ----------------------------------------------------------------------- */
    /*                                constructor()                            */
    /* ----------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(distributor.AIRLOCK()), address(airlock));
    }

    /* ----------------------------------------------------------------------- */
    /*                                setPullUp()                              */
    /* ----------------------------------------------------------------------- */

    function test_setPullUp() public {
        vm.prank(airlockOwner);
        distributor.setPullUp(migrator, true);

        assertTrue(distributor.canPullUp(migrator));
    }

    function test_setPullUp_disable() public {
        vm.startPrank(airlockOwner);
        distributor.setPullUp(migrator, true);
        assertTrue(distributor.canPullUp(migrator));

        distributor.setPullUp(migrator, false);
        assertFalse(distributor.canPullUp(migrator));
        vm.stopPrank();
    }

    function test_setPullUp_revertsWhenNotAirlockOwner() public {
        vm.expectRevert(SenderNotAirlockOwner.selector);
        distributor.setPullUp(migrator, true);
    }

    /* ----------------------------------------------------------------------- */
    /*                                topUp()                                  */
    /* ----------------------------------------------------------------------- */

    function test_topUp_withETH() public {
        vm.deal(address(this), 10 ether);

        distributor.topUp{ value: 10 ether }(asset, address(0), 10 ether);

        (address token0, address token1) = address(0) < asset ? (address(0), asset) : (asset, address(0));
        (uint256 amount, bool isToken0) = distributor.topUpOf(token0, token1);
        assertEq(amount, 10 ether);
        // asset > address(0), so asset is NOT token0
        assertFalse(isToken0);
        assertEq(address(distributor).balance, 10 ether);
    }

    function test_topUp_withERC20() public {
        TestERC20 numeraireToken = new TestERC20(type(uint256).max);
        numeraireToken.approve(address(distributor), 500e18);

        distributor.topUp(asset, address(numeraireToken), 500e18);

        (address token0, address token1) =
            asset < address(numeraireToken) ? (asset, address(numeraireToken)) : (address(numeraireToken), asset);
        (uint256 amount,) = distributor.topUpOf(token0, token1);
        assertEq(amount, 500e18);
        assertEq(numeraireToken.balanceOf(address(distributor)), 500e18);
    }

    function test_topUp_multipleDeposits() public {
        vm.deal(address(this), 30 ether);

        distributor.topUp{ value: 10 ether }(asset, address(0), 10 ether);
        distributor.topUp{ value: 20 ether }(asset, address(0), 20 ether);

        (address token0, address token1) = address(0) < asset ? (address(0), asset) : (asset, address(0));
        (uint256 amount,) = distributor.topUpOf(token0, token1);
        assertEq(amount, 30 ether);
    }

    function test_topUp_emitsEvent() public {
        vm.deal(address(this), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit TopUp(address(this), asset, address(0), 1 ether);

        distributor.topUp{ value: 1 ether }(asset, address(0), 1 ether);
    }

    function test_topUp_revertsWhenETHAmountMismatch() public {
        vm.deal(address(this), 10 ether);

        vm.expectRevert(InvalidETHAmount.selector);
        distributor.topUp{ value: 5 ether }(asset, address(0), 10 ether);
    }

    function test_topUp_revertsWhenETHSentWithERC20() public {
        TestERC20 numeraireToken = new TestERC20(type(uint256).max);
        numeraireToken.approve(address(distributor), 100e18);
        vm.deal(address(this), 1 ether);

        vm.expectRevert(InvalidETHAmount.selector);
        distributor.topUp{ value: 1 ether }(asset, address(numeraireToken), 100e18);
    }

    /* ----------------------------------------------------------------------- */
    /*                                pullUp()                                 */
    /* ----------------------------------------------------------------------- */

    function test_pullUp_withETH() public {
        // Setup: fund and enable migrator
        vm.deal(address(this), 10 ether);
        distributor.topUp{ value: 10 ether }(asset, address(0), 10 ether);
        vm.prank(airlockOwner);
        distributor.setPullUp(migrator, true);

        (address token0, address token1) = address(0) < asset ? (address(0), asset) : (asset, address(0));
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(migrator);
        distributor.pullUp(token0, token1, recipient);

        assertEq(recipient.balance, recipientBalanceBefore + 10 ether);
        (uint256 amount,) = distributor.topUpOf(token0, token1);
        assertEq(amount, 0);
    }

    function test_pullUp_withERC20() public {
        TestERC20 numeraireToken = new TestERC20(type(uint256).max);
        numeraireToken.approve(address(distributor), 500e18);
        distributor.topUp(asset, address(numeraireToken), 500e18);

        vm.prank(airlockOwner);
        distributor.setPullUp(migrator, true);

        (address token0, address token1) =
            asset < address(numeraireToken) ? (asset, address(numeraireToken)) : (address(numeraireToken), asset);

        vm.prank(migrator);
        distributor.pullUp(token0, token1, recipient);

        assertEq(numeraireToken.balanceOf(recipient), 500e18);
        (uint256 amount,) = distributor.topUpOf(token0, token1);
        assertEq(amount, 0);
    }

    function test_pullUp_clearsAmount() public {
        vm.deal(address(this), 10 ether);
        distributor.topUp{ value: 10 ether }(asset, address(0), 10 ether);
        vm.prank(airlockOwner);
        distributor.setPullUp(migrator, true);

        (address token0, address token1) = address(0) < asset ? (address(0), asset) : (asset, address(0));

        vm.startPrank(migrator);
        distributor.pullUp(token0, token1, recipient);

        // Second pull is a no-op, balance doesn't change
        uint256 recipientBalanceAfterFirst = recipient.balance;
        distributor.pullUp(token0, token1, recipient);
        assertEq(recipient.balance, recipientBalanceAfterFirst);
        vm.stopPrank();
    }

    function test_pullUp_noopWhenAmountIsZero() public {
        vm.prank(airlockOwner);
        distributor.setPullUp(migrator, true);

        (address token0, address token1) = address(0) < asset ? (address(0), asset) : (asset, address(0));
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(migrator);
        distributor.pullUp(token0, token1, recipient);

        assertEq(recipient.balance, recipientBalanceBefore);
    }

    function test_pullUp_emitsEvent() public {
        vm.deal(address(this), 5 ether);
        distributor.topUp{ value: 5 ether }(asset, address(0), 5 ether);
        vm.prank(airlockOwner);
        distributor.setPullUp(migrator, true);

        (address token0, address token1) = address(0) < asset ? (address(0), asset) : (asset, address(0));

        vm.expectEmit(true, true, true, true);
        emit PullUp(migrator, asset, address(0), recipient, 5 ether);

        vm.prank(migrator);
        distributor.pullUp(token0, token1, recipient);
    }

    function test_pullUp_revertsWhenSenderNotApproved() public {
        vm.deal(address(this), 10 ether);
        distributor.topUp{ value: 10 ether }(asset, address(0), 10 ether);

        (address token0, address token1) = address(0) < asset ? (address(0), asset) : (asset, address(0));

        vm.prank(migrator);
        vm.expectRevert(SenderCannotPullUp.selector);
        distributor.pullUp(token0, token1, recipient);
    }

    /* ----------------------------------------------------------------------- */
    /*                          isToken0 overwrite griefing                     */
    /* ----------------------------------------------------------------------- */

    /// @dev The fix prevents overwriting isToken0 when config.amount > 0,
    ///      but an attacker who frontruns the first legitimate deposit with
    ///      a dust amount still corrupts isToken0, permanently locking
    ///      the legitimate funds.
    function test_topUp_isToken0FrontrunLocksETH() public {
        (address token0, address token1) = address(0) < asset ? (address(0), asset) : (asset, address(0));

        // 1. Attacker frontruns with a 1 wei dust deposit using swapped roles
        //    (treats address(0) as asset, token as numeraire)
        address attacker = makeAddr("attacker");
        token.transfer(attacker, 1);
        vm.startPrank(attacker);
        token.approve(address(distributor), 1);
        distributor.topUp(address(0), asset, 1); // swapped roles, 1 wei of asset token
        vm.stopPrank();

        // isToken0 is now set to the attacker's orientation
        (, bool isToken0After) = distributor.topUpOf(token0, token1);
        assertTrue(isToken0After, "attacker set isToken0 = true");

        // 2. Legitimate user deposits 10 ETH — isToken0 is NOT updated because amount > 0
        vm.deal(address(this), 10 ether);
        distributor.topUp{ value: 10 ether }(asset, address(0), 10 ether);

        (, bool isToken0Final) = distributor.topUpOf(token0, token1);
        assertTrue(isToken0Final, "isToken0 still corrupted");

        // 3. pullUp reverts — tries to transfer asset token but contract mostly holds ETH
        vm.prank(airlockOwner);
        distributor.setPullUp(migrator, true);

        vm.prank(migrator);
        vm.expectRevert(); // safeTransfer of asset token fails
        distributor.pullUp(token0, token1, recipient);

        // ETH is permanently locked
        assertEq(address(distributor).balance, 10 ether);
    }
}
