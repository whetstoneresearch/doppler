// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionTestCompat } from "test/shared/OpeningAuctionTestCompat.sol";
import { IOpeningAuction, OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { OpeningAuctionDeployer } from "src/OpeningAuctionInitializer.sol";
import { OpeningAuctionTestDefaults } from "test/shared/OpeningAuctionTestDefaults.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionToken1Impl is OpeningAuctionTestCompat {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuctionTestCompat(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice OpeningAuctionDeployer that creates the implementation without address validation
contract OpeningAuctionToken1Deployer is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) {}

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionToken1Impl auction = new OpeningAuctionToken1Impl{salt: salt}(
            poolManager,
            msg.sender,
            auctionTokens,
            config
        );

        return OpeningAuction(payable(address(auction)));
    }
}

/// @title OpeningAuctionToken1DirectionTest
/// @notice Tests for OpeningAuction with isToken0=false (selling token1, price moves UP)
/// @dev This mirrors the isToken0=true tests but with inverse auction direction
contract OpeningAuctionToken1DirectionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    // Tokens - TOKEN_A > TOKEN_B so when asset=TOKEN_A, it becomes token1
    address constant TOKEN_A = address(0x9999);
    address constant TOKEN_B = address(0x8888);

    address asset;
    address numeraire;
    address token0;
    address token1;

    // Users
    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    address carol = address(0xca401);
    address creator = address(0xc4ea70);
    uint256 bidNonce;

    // Contracts
    OpeningAuctionToken1Deployer auctionDeployer;
    OpeningAuctionToken1Impl auction;
    PoolKey poolKey;

    // Auction parameters
    uint256 constant AUCTION_TOKENS = 100 ether;
    uint256 constant AUCTION_DURATION = 1 days;

    // Test configuration
    int24 tickSpacing = 60;
    int24 minTick;
    int24 minAcceptableTick; // Minimum acceptable price tick (tick(token0/token1))

    function _currentTick() internal view returns (int24) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens - ensure asset becomes token1 (higher address)
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_B);

        // For isToken0=false: asset is TOKEN_A (higher address = token1)
        asset = TOKEN_A;
        numeraire = TOKEN_B;
        
        // Verify asset is token1
        require(asset > numeraire, "Asset must be token1 for isToken0=false tests");
        token0 = numeraire;
        token1 = asset;

        vm.label(token0, "Token0-Numeraire");
        vm.label(token1, "Token1-Asset");

        // Deploy auction deployer
        auctionDeployer = new OpeningAuctionToken1Deployer(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Calculate tick values
        minTick = alignTickTowardZero(TickMath.MIN_TICK, tickSpacing);
        // Minimum acceptable price tick for isToken0=false as well.
        minAcceptableTick = -34_020;

        // Fund users
        _fundUser(alice, 100_000 ether, 100_000 ether);
        _fundUser(bob, 100_000 ether, 100_000 ether);
        _fundUser(carol, 100_000 ether, 100_000 ether);
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
            type(OpeningAuctionToken1Impl).creationCode,
            constructorArgs
        );
    }

    function _createAuction(OpeningAuctionConfig memory config) internal returns (OpeningAuctionToken1Impl) {
        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuctionToken1Impl _auction = OpeningAuctionToken1Impl(
            payable(address(auctionDeployer.deploy(AUCTION_TOKENS, salt, abi.encode(config))))
        );

        TestERC20(asset).transfer(address(_auction), AUCTION_TOKENS);
        
        // KEY DIFFERENCE: Set isToken0 to FALSE
        _auction.setPositionManager(address(modifyLiquidityRouter));
        _auction.setIsToken0(false);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(_auction))
        });

        // For isToken0=false: pool starts at MIN_TICK (price moves UP as tokens are sold)
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(minTick));
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
            abi.encodePacked(user)
        );
        vm.stopPrank();

        positionId = auction.getPositionId(user, tickLower, tickUpper, salt);
    }

    /// @notice Test basic deployment with isToken0=false
    function test_token1Direction_DeployAndInitialize() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -887_220,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        // Verify initial state
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active));
        assertFalse(auction.isToken0(), "isToken0 should be false");
        assertEq(auction.totalAuctionTokens(), AUCTION_TOKENS);

        // Pool should start at MIN_TICK for isToken0=false
        int24 currentTick = _currentTick();
        console2.log("Current tick (should be near MIN_TICK):", int256(currentTick));
        assertLe(currentTick, minTick + tickSpacing, "Current tick should be near MIN_TICK");
    }

    /// @notice Test placing bids with isToken0=false
    /// @dev For isToken0=false, lower ticks = lower price = higher priority
    function test_token1Direction_PlaceBids() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -887_220,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== Token1 Direction Bid Test ===");
        console2.log("Min tick (starting price):", int256(minTick));
        console2.log("Min acceptable tick:", int256(auction.minAcceptableTick()));
        console2.log("Current tick:", int256(_currentTick()));

        // For isToken0=false: Lower ticks are closer to starting price (MIN_TICK)
        // So lower tick bids fill first as price moves UP
        int24 lowTickBid = 0; // Close to MIN_TICK, high priority
        int24 highTickBid = 9960; // Further from MIN_TICK, lower priority (aligned to tickSpacing=60)

        // Place bid at low tick (high priority - fills first)
        uint256 alicePosId = _addBid(alice, lowTickBid, 50_000 ether);
        console2.log("Alice bid at tick:", int256(lowTickBid));

        // Place bid at higher tick (lower priority)
        uint256 bobPosId = _addBid(bob, highTickBid, 50_000 ether);
        console2.log("Bob bid at tick:", int256(highTickBid));

        // Verify positions
        AuctionPosition memory alicePos = auction.positions(alicePosId);
        AuctionPosition memory bobPos = auction.positions(bobPosId);

        assertEq(alicePos.owner, alice);
        assertEq(bobPos.owner, bob);
        assertEq(alicePos.tickLower, lowTickBid);
        assertEq(bobPos.tickLower, highTickBid);

        // Check in-range status
        // For isToken0=false: position is in range if estimatedClearingTick >= tickLower
        console2.log("Estimated clearing tick:", int256(auction.estimatedClearingTick()));
        console2.log("Alice isInRange:", auction.isInRange(alicePosId));
        console2.log("Bob isInRange:", auction.isInRange(bobPosId));
    }

    /// @notice Test settlement with isToken0=false
    function test_token1Direction_Settlement() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -887_220,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== Token1 Direction Settlement Test ===");

        // Place bids at various ticks
        // For isToken0=false: ascending order means lower ticks fill first
        int24 tick1 = 0;
        int24 tick2 = 600;
        int24 tick3 = 1200;

        uint256 pos1 = _addBid(alice, tick1, 50_000 ether);
        uint256 pos2 = _addBid(bob, tick2, 50_000 ether);
        uint256 pos3 = _addBid(carol, tick3, 30_000 ether);

        console2.log("Positions placed at ticks:", int256(tick1));
        console2.log("  ", int256(tick2));
        console2.log("  ", int256(tick3));
        console2.log("Estimated clearing tick before settlement:", int256(auction.estimatedClearingTick()));

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Capture state before settlement
        uint256 hookAssetBefore = TestERC20(asset).balanceOf(address(auction));
        uint256 hookNumeraireBefore = TestERC20(numeraire).balanceOf(address(auction));

        console2.log("Hook asset (token1) before:", hookAssetBefore);
        console2.log("Hook numeraire (token0) before:", hookNumeraireBefore);

        // Settle auction
        auction.settleAuction();

        // Verify settlement
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));

        console2.log("\n=== Settlement Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("Tokens sold:", auction.totalTokensSold());
        console2.log("Proceeds:", auction.totalProceeds());

        // For isToken0=false: clearing tick should have moved UP from MIN_TICK
        assertGt(auction.clearingTick(), minTick, "Clearing tick should be above MIN_TICK");
        assertLe(
            auction.clearingTick(),
            auction.minAcceptableTick(),
            "Clearing tick should not exceed minAcceptableTick"
        );
        assertGe(auction.totalTokensSold(), 0, "Tokens sold should be non-negative");

        // Verify positions and incentives
        console2.log("\n=== Position States ===");
        _logPositionState("Alice", pos1);
        _logPositionState("Bob", pos2);
        _logPositionState("Carol", pos3);
    }

    /// @notice Test incentive accumulation with isToken0=false
    function test_token1Direction_IncentiveAccumulation() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: 4 hours,
            minAcceptableTickToken0: -887_220,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== Token1 Direction Incentive Test ===");

        // Place a bid that will be in range
        int24 bidTick = 0;
        uint256 posId = _addBid(alice, bidTick, 100_000 ether);

        console2.log("Position placed at tick:", int256(bidTick));
        console2.log("Initial isInRange:", auction.isInRange(posId));
        console2.log("Initial accumulatedTime:", auction.getPositionAccumulatedTime(posId));

        // Warp halfway
        vm.warp(auction.auctionStartTime() + 2 hours);
        console2.log("\nAfter 2 hours:");
        console2.log("isInRange:", auction.isInRange(posId));
        console2.log("accumulatedTime:", auction.getPositionAccumulatedTime(posId));

        // Warp to end and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\nAfter settlement:");
        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("Final accumulatedTime:", auction.getPositionAccumulatedTime(posId));

        uint256 incentives = auction.calculateIncentives(posId);
        console2.log("Calculated incentives:", incentives);

        // If position was in range, should have incentives
        if (auction.clearingTick() >= bidTick) {
            assertGt(auction.getPositionAccumulatedTime(posId), 0, "Should have accumulated time");
            assertGt(incentives, 0, "Should have incentives");
        }
    }

    /// @notice Test bid rejection when tick is above minAcceptableTick
    function test_token1Direction_RejectBidBelowMinTick() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -887_220,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        int24 limitTick = auction.minAcceptableTick();
        int24 invalidTickLower = limitTick + tickSpacing;

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(auction),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IOpeningAuction.BidBelowMinimumPrice.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: invalidTickLower,
                tickUpper: invalidTickLower + tickSpacing,
                liquidityDelta: int256(uint256(1e18)),
                salt: bytes32(uint256(1))
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();
    }

    /// @notice Test multiple bidders with different fill status
    function test_token1Direction_PartialFill() public {
        uint256 smallAuctionTokens = 30 ether;

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -887_220,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        // Deploy with smaller token amount
        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            smallAuctionTokens,
            config
        );

        vm.startPrank(creator);
        auction = OpeningAuctionToken1Impl(
            payable(address(auctionDeployer.deploy(smallAuctionTokens, salt, abi.encode(config))))
        );

        TestERC20(asset).transfer(address(auction), smallAuctionTokens);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(minTick));
        vm.stopPrank();

        console2.log("=== Token1 Direction Partial Fill Test ===");
        console2.log("Auction tokens:", smallAuctionTokens);

        // Place massive liquidity at low tick (will absorb all tokens)
        int24 lowTick = 0;
        _addBid(alice, lowTick, 90_000 ether);
        console2.log("Alice: massive liquidity at tick 0");

        // Place liquidity at higher tick (may not fill)
        int24 highTick = 30000;
        uint256 highPosId = _addBid(bob, highTick, 10_000 ether);
        console2.log("Bob: liquidity at tick", int256(highTick));

        // Settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        // For isToken0=false: positions are in range if clearingTick >= tickLower
        // If clearingTick < highTick, Bob's position was NOT filled
        if (auction.clearingTick() < highTick) {
            console2.log("Bob's position was NOT filled");
            assertEq(auction.getPositionAccumulatedTime(highPosId), 0, "Unfilled should have 0 time");
        } else {
            console2.log("Bob's position WAS filled");
        }

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));
    }

    function _logPositionState(string memory name, uint256 posId) internal view {
        AuctionPosition memory pos = auction.positions(posId);
        console2.log(string.concat(name, " - tick:"), int256(pos.tickLower));
        console2.log(string.concat(name, " - inRange:"), auction.isInRange(posId));
        console2.log(string.concat(name, " - accTime:"), auction.getPositionAccumulatedTime(posId));
        console2.log(string.concat(name, " - incentives:"), auction.calculateIncentives(posId));
    }
}
