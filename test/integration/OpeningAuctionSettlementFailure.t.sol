// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { OpeningAuctionDeployer } from "src/OpeningAuctionInitializer.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";
import { OpeningAuctionTestDefaults } from "test/shared/OpeningAuctionTestDefaults.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionFailureImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice OpeningAuctionDeployer that creates the implementation without address validation
contract OpeningAuctionFailureDeployer is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) {}

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionFailureImpl auction = new OpeningAuctionFailureImpl{salt: salt}(
            poolManager,
            msg.sender,
            auctionTokens,
            config
        );

        return OpeningAuction(payable(address(auction)));
    }
}

/// @title OpeningAuctionSettlementFailureTest
/// @notice Tests for settlement edge cases
/// @dev Tests partial fill at price limit and no-bids edge case
contract OpeningAuctionSettlementFailureTest is Test, Deployers {
    // Tokens
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;
    address token0;
    address token1;

    // Users
    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    uint256 bidNonce;
    address creator = address(0xc4ea70);

    // Contracts
    OpeningAuctionFailureDeployer auctionDeployer;
    OpeningAuction auction;
    PoolKey poolKey;

    // Auction parameters
    uint256 constant AUCTION_TOKENS = 100 ether;
    uint256 constant AUCTION_DURATION = 1 days;

    int24 tickSpacing = 60;
    int24 maxTick;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        // Deploy auction deployer
        auctionDeployer = new OpeningAuctionFailureDeployer(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Calculate tick values
        maxTick = alignTickTowardZero(TickMath.MAX_TICK, tickSpacing);

        // Fund users
        _fundUser(alice, 100_000 ether, 100_000 ether);
        _fundUser(bob, 100_000 ether, 100_000 ether);
        TestERC20(asset).transfer(creator, AUCTION_TOKENS);
    }

    function _fundUser(address user, uint256 amount0, uint256 amount1) internal {
        TestERC20(token0).transfer(user, amount0);
        TestERC20(token1).transfer(user, amount1);
    }

    function getHookFlags() internal pure returns (uint160) {
        return OpeningAuctionTestDefaults.hookFlags();
    }

    function mineHookSalt(
        address deployer,
        address caller,
        uint256 auctionTokens,
        OpeningAuctionConfig memory config
    ) internal view returns (bytes32 salt, address hookAddress) {
        bytes memory constructorArgs = abi.encode(
            manager,
            caller,
            auctionTokens,
            config
        );

        (hookAddress, salt) = HookMiner.find(
            deployer,
            getHookFlags(),
            type(OpeningAuctionFailureImpl).creationCode,
            constructorArgs
        );
    }

    function _createAuction(OpeningAuctionConfig memory config) internal returns (OpeningAuction) {
        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction _auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );

        TestERC20(asset).transfer(address(_auction), AUCTION_TOKENS);
        _auction.setPositionManager(address(modifyLiquidityRouter));
        _auction.setIsToken0(true);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(_auction))
        });

        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(maxTick));
        vm.stopPrank();

        return _auction;
    }

    function _addBid(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + tickSpacing;
        bytes32 salt = keccak256(abi.encode(user, bidNonce++));

        vm.startPrank(user);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

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
        vm.stopPrank();

        positionId = auction.getPositionId(user, tickLower, tickUpper, salt);
    }

    /// @notice Test settlement partial fill for isToken0=true when bids are insufficient
    function test_settlementPartialFill_PriceTooLow_isToken0True() public {
        // Set a HIGH minAcceptableTick - only bids at very high price are acceptable
        int24 highMinAcceptableTick = 0; // Require clearing tick >= 0

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: highMinAcceptableTick,
            minAcceptableTickToken1: -887_220,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== SettlementPriceTooLow Test (isToken0=true) ===");
        console2.log("minAcceptableTick:", int256(highMinAcceptableTick));

        // Place a small bid at a LOW tick (below minAcceptableTick)
        // The bid itself is allowed because tickLower >= minAcceptableTick check is for where bids can be placed
        // But if there's not enough liquidity at high ticks, clearing will be too low
        
        // Place minimal liquidity at valid tick (>= minAcceptableTick)
        int24 validTick = highMinAcceptableTick; // Exactly at minAcceptableTick
        _addBid(alice, validTick, 1e15); // Minimum liquidity - very small

        console2.log("Placed tiny bid at tick:", int256(validTick));
        console2.log("Estimated clearing tick:", int256(auction.estimatedClearingTick()));

        // The tiny bid won't absorb all 100 ether tokens
        // So clearing tick will be much lower than minAcceptableTick

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        auction.settleAuction();
        uint256 tokensToSell = AUCTION_TOKENS - auction.incentiveTokensTotal();
        assertLt(auction.totalTokensSold(), tokensToSell);
        assertEq(auction.clearingTick(), highMinAcceptableTick);
    }

    /// @notice Test settlement with NO bids (empty activeTicks array)
    /// @dev Should settle with 0 tokens sold, no revert
    function test_settlementSuccess_NoBids() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -34_020,
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== No Bids Settlement Test ===");
        console2.log("Phase before settlement:", uint8(auction.phase()));

        // NO BIDS PLACED - activeTicks is empty

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Settlement should succeed (no swap executed)
        auction.settleAuction();

        // Verify state
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled), "Should be settled");
        assertEq(auction.totalTokensSold(), 0, "Should have sold 0 tokens");
        assertEq(auction.totalProceeds(), 0, "Should have 0 proceeds");
        assertEq(auction.clearingTick(), auction.minAcceptableTick(), "Should use minAcceptableTick");

        vm.prank(creator);
        (uint160 sqrtPriceX96,,,,,,) = auction.migrate(creator);
        assertEq(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(auction.clearingTick()),
            "sqrtPrice should match clearingTick"
        );

        console2.log("Phase after settlement:", uint8(auction.phase()));
        console2.log("Tokens sold:", auction.totalTokensSold());
        console2.log("Clearing tick:", int256(auction.clearingTick()));
    }

    /// @notice Test settlement with insufficient liquidity at the price limit
    /// @dev Bids below the limit are rejected; settlement should partially fill to the limit
    function test_settlementFailure_InsufficientLiquidity() public {
        // Very high minAcceptableTick - hard to satisfy
        int24 veryHighMinTick = 60_000;

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: veryHighMinTick,
            minAcceptableTickToken1: veryHighMinTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== Insufficient Liquidity Test ===");
        console2.log("minAcceptableTick:", int256(veryHighMinTick));

        // Place minimal bid at the minimum acceptable tick
        int24 bidTick = veryHighMinTick;
        _addBid(alice, bidTick, 1e15); // Minimal liquidity

        console2.log("Placed minimal bid at tick:", int256(bidTick));
        console2.log("Estimated clearing tick:", int256(auction.estimatedClearingTick()));

        // With only minimal liquidity, the clearing tick will be way below minAcceptableTick
        // when trying to sell 100 ether tokens

        vm.warp(auction.auctionEndTime() + 1);

        auction.settleAuction();
        uint256 tokensToSell = AUCTION_TOKENS - auction.incentiveTokensTotal();
        assertLt(auction.totalTokensSold(), tokensToSell);
        assertEq(auction.clearingTick(), veryHighMinTick);
    }

    /// @notice Test that settlement cannot happen before auction ends
    function test_settlementFailure_AuctionNotEnded() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -34_020,
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        // Place a bid
        _addBid(alice, 0, 100_000 ether);

        // Try to settle before auction ends
        vm.expectRevert(abi.encodeWithSignature("AuctionNotEnded()"));
        auction.settleAuction();
    }

    /// @notice Test that settlement cannot happen twice
    function test_settlementFailure_AlreadySettled() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -34_020,
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        // Place a bid with enough liquidity
        _addBid(alice, 0, 100_000 ether);

        // Warp and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        // Try to settle again
        vm.expectRevert(abi.encodeWithSignature("AuctionNotActive()"));
        auction.settleAuction();
    }

    /// @notice Test settlement with isToken0=false and high minAcceptableTick floor
    /// @dev Bid validation enforces tickLower <= minAcceptableTick, so settlement should succeed
    function test_settlementFailure_PriceTooHigh_isToken0False() public {
        // For isToken0=false tests, we need asset to be token1
        // Redeploy with swapped tokens
        address newAsset = TOKEN_B; // Higher address = token1
        address newNumeraire = TOKEN_A;
        
        // Only run if TOKEN_B > TOKEN_A for proper isToken0=false setup
        assertGt(uint256(uint160(TOKEN_B)), uint256(uint160(TOKEN_A)), "Token ordering must be TOKEN_B > TOKEN_A");

        (token0, token1) = (newNumeraire, newAsset);
        asset = newAsset;
        numeraire = newNumeraire;

        // Set a HIGH minAcceptableTick - clearing tick must reach this floor
        int24 highMinAcceptableTick = 0; // tick(token0/token1), ceiling is 0 in pool space

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: highMinAcceptableTick,
            minAcceptableTickToken1: highMinAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        TestERC20(asset).transfer(creator, AUCTION_TOKENS);

        vm.startPrank(creator);
        auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );

        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false); // KEY: isToken0 = false

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        // For isToken0=false: start at MIN_TICK
        int24 minTick = alignTickTowardZero(TickMath.MIN_TICK, tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(minTick));
        vm.stopPrank();

        console2.log("=== SettlementPriceTooLow Test (isToken0=false) ===");
        console2.log("minAcceptableTick:", int256(auction.minAcceptableTick()));
        assertFalse(auction.isToken0(), "Should be isToken0=false");

        int24 limitTick = auction.minAcceptableTick();
        int24 validTick = limitTick - tickSpacing;
        
        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: validTick,
                tickUpper: validTick + tickSpacing,
                liquidityDelta: int256(uint256(1e15)), // Minimal liquidity
                salt: bytes32(uint256(1))
            }),
            abi.encode(alice)
        );
        vm.stopPrank();

        console2.log("Placed minimal bid at tick:", int256(validTick));
        console2.log("Estimated clearing tick:", int256(auction.estimatedClearingTick()));

        vm.warp(auction.auctionEndTime() + 1);

        auction.settleAuction();
        uint256 tokensToSell = AUCTION_TOKENS - auction.incentiveTokensTotal();
        assertLt(auction.totalTokensSold(), tokensToSell);
        assertEq(auction.clearingTick(), limitTick);
    }

    /// @notice Test incentive recovery when no positions earned time
    function test_recoverIncentives_WhenNoBidsEarnedTime() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -34_020,
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        // NO BIDS - settle with 0 weighted time

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        // cachedTotalWeightedTimeX128 should be 0
        assertEq(auction.cachedTotalWeightedTimeX128(), 0, "Should have 0 weighted time");

        uint256 incentivesBefore = auction.incentiveTokensTotal();
        assertGt(incentivesBefore, 0, "Should have incentive tokens");

        // Recover incentives (must be called by initializer)
        address initializerAddr = auction.initializer();
        address recipient = address(0xdead);

        vm.prank(initializerAddr);
        auction.migrate(initializerAddr);

        vm.prank(initializerAddr);
        auction.recoverIncentives(recipient);

        // Verify recovery
        uint256 recipientBalance = TestERC20(asset).balanceOf(recipient);
        assertEq(recipientBalance, incentivesBefore, "Should have received incentives");
        assertEq(auction.incentiveTokensTotal(), 0, "Incentives should be zeroed");
    }
}
