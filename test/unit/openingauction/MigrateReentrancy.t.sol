// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPosition, IOpeningAuction } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

import { IERC20Minimal } from "@v4-core/interfaces/external/IERC20Minimal.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";

contract ReentrantERC20 is IERC20Minimal {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    bool public reenterEnabled;
    bool public reenterAttempted;
    bool public reenterSucceeded;
    address public reenterTarget;
    uint256 public reenterPositionId;

    constructor(uint256 amountToMint) {
        mint(msg.sender, amountToMint);
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function setReenterTarget(address target, uint256 positionId) external {
        reenterTarget = target;
        reenterPositionId = positionId;
        reenterEnabled = true;
        reenterAttempted = false;
        reenterSucceeded = false;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        _maybeReenter();
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        uint256 allowanceBefore = allowance[sender][msg.sender];
        require(allowanceBefore >= amount, "allowance insufficient");
        allowance[sender][msg.sender] = allowanceBefore - amount;
        _transfer(sender, recipient, amount);
        _maybeReenter();
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        uint256 balanceBefore = balanceOf[sender];
        require(balanceBefore >= amount, "insufficient balance");
        balanceOf[sender] = balanceBefore - amount;
        balanceOf[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }

    function _maybeReenter() internal {
        if (!reenterEnabled || reenterAttempted || reenterTarget == address(0)) return;
        reenterAttempted = true;

        try IOpeningAuction(reenterTarget).claimIncentives(reenterPositionId) {
            reenterSucceeded = true;
        } catch {
            // Expected to revert during migrate
        }
    }
}

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionReentrancyImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract MigrateReentrancyTest is Test, Deployers {
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;
    address token0;
    address token1;

    address alice = address(0xa71c3);
    address initializer = address(0xbeef);

    OpeningAuctionReentrancyImpl hook;
    PoolKey poolKey;
    uint256 bidNonce;

    function setUp() public {
        manager = new PoolManager(address(this));

        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("MigrateReentrancy.t.sol:ReentrantERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: 1 days,
            minAcceptableTickToken0: -34_020,
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        address hookAddress = address(uint160(_getHookFlags()) ^ (0x4444 << 144));
        deployCodeTo(
            "MigrateReentrancy.t.sol:OpeningAuctionReentrancyImpl",
            abi.encode(manager, initializer, 100 ether, config),
            hookAddress
        );

        hook = OpeningAuctionReentrancyImpl(payable(hookAddress));
        TestERC20(asset).transfer(address(hook), 100 ether);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });

        vm.prank(initializer);
        hook.setIsToken0(true);

        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, config.tickSpacing);
        vm.prank(initializer);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        TestERC20(token0).transfer(alice, 1_000_000 ether);
        ReentrantERC20(token1).transfer(alice, 1_000_000 ether);

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        ReentrantERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_migrateBlocksReentrantClaim() public {
        int24 tickLower = 0;
        uint128 liquidity = hook.minLiquidity() * 10;
        uint256 positionId = _addBid(alice, tickLower, liquidity);

        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();

        assertGt(hook.totalProceeds(), 0, "expected proceeds for reentrancy test");

        ReentrantERC20(token1).setReenterTarget(address(hook), positionId);

        vm.prank(initializer);
        hook.migrate(address(this));

        assertTrue(ReentrantERC20(token1).reenterAttempted(), "reentry not attempted");
        assertFalse(ReentrantERC20(token1).reenterSucceeded(), "reentry should fail");

        AuctionPosition memory pos = hook.positions(positionId);
        assertFalse(pos.hasClaimedIncentives, "claim should not succeed during migrate");
    }

    function _getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_DONATE_FLAG
        );
    }

    function _addBid(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + poolKey.tickSpacing;
        bytes32 salt = keccak256(abi.encode(user, bidNonce++));

        vm.prank(user);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(user)
        );

        positionId = hook.getPositionId(user, tickLower, tickUpper, salt);
    }
}
