// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionFeeImpactImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract OpeningAuctionFeeImpactTest is Test, Deployers {
    uint160 constant FLAG_MASK = 0x3FFF;

    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    uint256 constant AUCTION_TOKENS = 100 ether;

    address asset;
    address numeraire;
    address token0;
    address token1;

    address alice = address(0xa71c3);
    address initializer = address(0xbeef);
    uint256 bidNonce;

    function setUp() public {
        manager = new PoolManager(address(this));

        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        TestERC20(token0).transfer(alice, 10_000_000 ether);
        TestERC20(token1).transfer(alice, 10_000_000 ether);

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_fee0_producesMoreProceedsThanNonZeroFee() public {
        OpeningAuctionConfig memory configFee0 = _getConfig(0);
        OpeningAuctionConfig memory configFee3000 = _getConfig(3000);

        (OpeningAuctionFeeImpactImpl hookFee0, PoolKey memory keyFee0) = _deployAuction(configFee0, 0x1111);
        (OpeningAuctionFeeImpactImpl hookFee3000, PoolKey memory keyFee3000) = _deployAuction(configFee3000, 0x2222);

        int24 baseTick = hookFee0.minAcceptableTick() + int24(10 * configFee0.tickSpacing);
        uint128 liquidity = 1e20;
        uint256 numTicks = 20;

        for (uint256 i = 0; i < numTicks; i++) {
            int24 tickLower = baseTick + int24(int256(uint256(i)) * int256(configFee0.tickSpacing));
            _addBid(hookFee0, keyFee0, alice, tickLower, liquidity);
            _addBid(hookFee3000, keyFee3000, alice, tickLower, liquidity);
        }

        vm.warp(hookFee0.auctionEndTime() + 1);
        hookFee0.settleAuction();
        hookFee3000.settleAuction();

        uint256 soldFee0 = hookFee0.totalTokensSold();
        uint256 soldFee3000 = hookFee3000.totalTokensSold();

        assertGt(soldFee0, 0);
        assertGt(soldFee3000, 0);
        assertLe(soldFee0, soldFee3000);

        uint256 avgPriceFee0 = (hookFee0.totalProceeds() * 1e18) / soldFee0;
        uint256 avgPriceFee3000 = (hookFee3000.totalProceeds() * 1e18) / soldFee3000;
        assertGt(avgPriceFee0, avgPriceFee3000);
    }

    function _deployAuction(
        OpeningAuctionConfig memory config,
        uint256 hookSalt
    ) internal returns (OpeningAuctionFeeImpactImpl hook, PoolKey memory poolKey) {
        bool isToken0 = asset < numeraire;

        uint160 base = uint160(uint256(keccak256(abi.encode(config.fee, hookSalt))));
        address hookAddress = address((base & ~FLAG_MASK) | _openingAuctionHookFlags());

        deployCodeTo(
            "OpeningAuctionFeeImpact.t.sol:OpeningAuctionFeeImpactImpl",
            abi.encode(manager, initializer, AUCTION_TOKENS, config),
            hookAddress
        );

        hook = OpeningAuctionFeeImpactImpl(payable(hookAddress));

        TestERC20(asset).transfer(address(hook), AUCTION_TOKENS);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(initializer);
        hook.setIsToken0(isToken0);
        int24 startingTick = alignTickTowardZero(
            isToken0 ? TickMath.MAX_TICK : TickMath.MIN_TICK,
            config.tickSpacing
        );
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();
    }

    function _addBid(
        OpeningAuctionFeeImpactImpl hook,
        PoolKey memory poolKey,
        address bidder,
        int24 tickLower,
        uint128 liquidity
    ) internal returns (uint256 positionId) {
        bytes32 salt = keccak256(abi.encode(bidder, bidNonce++));
        vm.startPrank(bidder);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + poolKey.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(bidder)
        );
        vm.stopPrank();

        positionId = hook.getPositionId(bidder, tickLower, tickLower + poolKey.tickSpacing, salt);
    }

    function _openingAuctionHookFlags() internal pure returns (uint160) {
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

    function _getConfig(uint24 fee) internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: 1 days,
            minAcceptableTickToken0: -34_020,
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: 60,
            fee: fee,
            minLiquidity: 1e15
        });
    }
}
