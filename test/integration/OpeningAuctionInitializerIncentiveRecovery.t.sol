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
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { Airlock } from "src/Airlock.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import {
    OpeningAuctionInitializer,
    OpeningAuctionDeployer,
    OpeningAuctionInitData,
    IDopplerDeployer
} from "src/OpeningAuctionInitializer.sol";

contract DopplerDeployerMock is IDopplerDeployer {
    function deploy(uint256, bytes32, bytes calldata) external pure returns (Doppler) {
        revert("Doppler deployer not used");
    }
}

contract OpeningAuctionInitializerIncentiveRecoveryTest is Test, Deployers {
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    uint256 constant AUCTION_TOKENS = 100 ether;

    address asset;
    address numeraire;
    address token0;
    address token1;

    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    address caller = address(0xc011a7);
    address airlockOwner = address(0xA11CE);

    uint256 bidNonce;

    Airlock airlock;
    OpeningAuctionInitializer initializer;
    OpeningAuctionDeployer auctionDeployer;
    DopplerDeployerMock dopplerDeployer;

    function setUp() public {
        manager = new PoolManager(address(this));

        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        airlock = new Airlock(airlockOwner);
        auctionDeployer = new OpeningAuctionDeployer(manager);
        dopplerDeployer = new DopplerDeployerMock();
        initializer = new OpeningAuctionInitializer(address(airlock), manager, auctionDeployer, dopplerDeployer);

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        TestERC20(asset).transfer(address(airlock), AUCTION_TOKENS);

        vm.prank(address(airlock));
        TestERC20(asset).approve(address(initializer), type(uint256).max);

        TestERC20(token0).transfer(alice, 10_000_000 ether);
        TestERC20(token1).transfer(alice, 10_000_000 ether);
        TestERC20(token0).transfer(bob, 10_000_000 ether);
        TestERC20(token1).transfer(bob, 10_000_000 ether);

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_sweepOpeningAuctionIncentives_permissionless_sendsToAirlockOwner() public {
        OpeningAuction hook = _initializeAuction(AUCTION_TOKENS);
        PoolKey memory key = _buildPoolKey(hook);

        int24 tickLower = hook.minAcceptableTick();
        uint128 liquidity = hook.minLiquidity() * 10;

        uint256 alicePos = _addBid(hook, key, alice, tickLower, liquidity);
        _addBid(hook, key, bob, tickLower, liquidity);

        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();

        vm.prank(address(initializer));
        hook.migrate(address(this));

        uint256 aliceIncentives = hook.calculateIncentives(alicePos);

        vm.prank(alice);
        hook.claimIncentives(alicePos);

        vm.warp(hook.incentivesClaimDeadline() + 1);

        uint256 remaining = hook.incentiveTokensTotal() - aliceIncentives;

        uint256 ownerBefore = TestERC20(asset).balanceOf(airlockOwner);
        vm.prank(caller);
        initializer.sweepOpeningAuctionIncentives(asset);
        uint256 ownerAfter = TestERC20(asset).balanceOf(airlockOwner);

        assertEq(ownerAfter - ownerBefore, remaining);
    }

    function test_recoverOpeningAuctionIncentives_permissionless_sendsToAirlockOwner() public {
        OpeningAuction hook = _initializeAuction(AUCTION_TOKENS);

        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();

        vm.prank(address(initializer));
        hook.migrate(address(this));

        uint256 incentives = hook.incentiveTokensTotal();

        uint256 ownerBefore = TestERC20(asset).balanceOf(airlockOwner);
        vm.prank(caller);
        initializer.recoverOpeningAuctionIncentives(asset);
        uint256 ownerAfter = TestERC20(asset).balanceOf(airlockOwner);

        assertEq(ownerAfter - ownerBefore, incentives);
        assertEq(hook.incentiveTokensTotal(), 0);
    }

    function _initializeAuction(uint256 auctionTokens) internal returns (OpeningAuction) {
        OpeningAuctionConfig memory config = _getAuctionConfig();
        OpeningAuctionInitData memory initData = OpeningAuctionInitData({
            auctionConfig: config,
            shareToAuctionBps: 10_000,
            dopplerData: _getDopplerData(30, asset < numeraire)
        });

        bytes32 auctionSalt = _mineOpeningAuctionSalt(config, auctionTokens);
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, auctionTokens, auctionSalt, abi.encode(initData));
        return OpeningAuction(payable(initializer.getOpeningAuctionHook(asset)));
    }

    function _buildPoolKey(OpeningAuction hook) internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = hook.poolKey();
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function _addBid(
        OpeningAuction hook,
        PoolKey memory key,
        address bidder,
        int24 tickLower,
        uint128 liquidity
    ) internal returns (uint256 positionId) {
        bytes32 salt = keccak256(abi.encode(bidder, bidNonce++));

        vm.startPrank(bidder);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(bidder)
        );
        vm.stopPrank();

        positionId = hook.getPositionId(bidder, tickLower, tickLower + key.tickSpacing, salt);
    }

    function _mineOpeningAuctionSalt(OpeningAuctionConfig memory config, uint256 auctionTokens)
        internal
        view
        returns (bytes32)
    {
        bytes memory constructorArgs = abi.encode(manager, address(initializer), auctionTokens, config);
        (, bytes32 salt) = HookMiner.find(
            address(auctionDeployer),
            _openingAuctionHookFlags(),
            type(OpeningAuction).creationCode,
            constructorArgs
        );
        return salt;
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

    function _getAuctionConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: 1 days,
            minAcceptableTickToken0: -1_800,
            minAcceptableTickToken1: -1_800,
            incentiveShareBps: 1000,
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e12
        });
    }

    function _getDopplerData(int24 tickSpacing, bool isToken0) internal view returns (bytes memory) {
        return abi.encode(
            uint256(0),
            uint256(1e30),
            block.timestamp + 1 days,
            block.timestamp + 8 days,
            int24(0),
            int24(-100_000),
            uint256(1 hours),
            int24(300),
            isToken0,
            uint256(5),
            uint24(3000),
            tickSpacing
        );
    }
}
