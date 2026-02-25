// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Airlock } from "src/Airlock.sol";
import {
    InconsistentOrientation,
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

    /// @dev Mixed-unit accounting: an attacker tries to inflate a pair's amount counter by
    ///      depositing worthless asset tokens via reversed topUp arguments. The fix rejects
    ///      reversed-orientation deposits, so the victim's funds remain safe.
    function test_pullUp_CannotPullUpMoreThanToppedUp() public {
        vm.prank(airlockOwner);
        distributor.setPullUp(address(this), true);

        TestERC20 numeraireToken = new TestERC20(type(uint256).max);
        TestERC20 victimAsset = new TestERC20(0);
        TestERC20 attackerAsset = new TestERC20(type(uint256).max);

        // 1. Victim tops up pair (victimAsset, numeraireToken) with 1000 real numeraire
        numeraireToken.approve(address(distributor), type(uint256).max);
        distributor.topUp(address(victimAsset), address(numeraireToken), 1000e18);

        // 2. Attacker seeds pair (attackerAsset, numeraireToken) with 1 wei numeraire
        //    to lock in the correct isToken0 orientation
        address attacker = makeAddr("attacker");
        numeraireToken.transfer(attacker, 1);
        attackerAsset.transfer(attacker, 999e18);

        vm.startPrank(attacker);
        numeraireToken.approve(address(distributor), 1);
        distributor.topUp(address(attackerAsset), address(numeraireToken), 1);

        // 3. Attacker tries to call topUp with reversed labels — this is now rejected
        attackerAsset.approve(address(distributor), 999e18);
        vm.expectRevert(InconsistentOrientation.selector);
        distributor.topUp(address(numeraireToken), address(attackerAsset), 999e18);
        vm.stopPrank();

        // 4. Attacker's pair only has the 1 wei seed — pullUp pays out just that
        (address t0Atk, address t1Atk) = address(attackerAsset) < address(numeraireToken)
            ? (address(attackerAsset), address(numeraireToken))
            : (address(numeraireToken), address(attackerAsset));
        (uint256 attackerAmount,) = distributor.topUpOf(t0Atk, t1Atk);
        assertEq(attackerAmount, 1);

        address attackerRecipient = makeAddr("AttackerRecipient");
        distributor.pullUp(t0Atk, t1Atk, attackerRecipient);
        assertEq(numeraireToken.balanceOf(attackerRecipient), 1);

        // 5. Victim's pullUp succeeds — their 1000e18 numeraire is intact
        (address t0Vic, address t1Vic) = address(victimAsset) < address(numeraireToken)
            ? (address(victimAsset), address(numeraireToken))
            : (address(numeraireToken), address(victimAsset));

        address victimRecipient = makeAddr("VictimRecipient");
        distributor.pullUp(t0Vic, t1Vic, victimRecipient);
        assertEq(numeraireToken.balanceOf(victimRecipient), 1000e18);
    }

    /* ----------------------------------------------------------------------- */
    /*                          isToken0 overwrite griefing                     */
    /* ----------------------------------------------------------------------- */

    /// @dev Attacker frontruns with a dust deposit using swapped roles. The legitimate
    ///      user's deposit is rejected because the orientation doesn't match, so the
    ///      attacker can only grief by locking in a wrong orientation for a pair that
    ///      has no legitimate deposits yet. The legitimate user must then use the same
    ///      orientation or start fresh with a different pair.
    function test_topUp_isToken0FrontrunLocksETH() public {
        // 1. Attacker frontruns with a 1 wei dust deposit using swapped roles
        //    (treats address(0) as asset, token as numeraire)
        address attacker = makeAddr("attacker");
        token.transfer(attacker, 1);
        vm.startPrank(attacker);
        token.approve(address(distributor), 1);
        distributor.topUp(address(0), asset, 1); // swapped roles, 1 wei of asset token
        vm.stopPrank();

        // 2. Legitimate user tries to deposit 10 ETH with the correct orientation —
        //    this is now rejected because the stored orientation doesn't match
        vm.deal(address(this), 10 ether);
        vm.expectRevert(InconsistentOrientation.selector);
        distributor.topUp{ value: 10 ether }(asset, address(0), 10 ether);

        // Legitimate user's ETH is NOT stuck — the deposit was rejected
        assertEq(address(this).balance, 10 ether);
    }
}
