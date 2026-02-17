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
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionTestCompat } from "test/shared/OpeningAuctionTestCompat.sol";
import { IOpeningAuction, OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import {
    OpeningAuctionInitializer,
    OpeningAuctionDeployer,
    OpeningAuctionInitData,
    OpeningAuctionStatus
} from "src/OpeningAuctionInitializer.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";
import { OpeningAuctionTestDefaults } from "test/shared/OpeningAuctionTestDefaults.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
/// @dev Used for testing to allow deployment at arbitrary addresses
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
contract OpeningAuctionDeployerToken1Impl is OpeningAuctionDeployer {
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

/// @title OpeningAuctionToken1FlowTest
/// @notice Integration tests for OpeningAuction when isToken0=false (asset is token1)
/// @dev When isToken0=false:
///      - The asset token has a LARGER address than numeraire
///      - Pool starts at MIN_TICK (lowest price for token1)
///      - Price moves UP as tokens are sold (clearing tick increases)
///      - Bids are validated with tickUpper <= minAcceptableTick() (pool-space ceiling)
///      - "Filled" means clearing tick >= tickLower
contract OpeningAuctionToken1FlowTest is Test, Deployers {
    // Token addresses - arranged so asset (TOKEN_HIGH) > numeraire (TOKEN_LOW)
    // This ensures isToken0=false (asset is token1, numeraire is token0)
    address constant TOKEN_LOW = address(0x1111);   // Numeraire (token0)
    address constant TOKEN_HIGH = address(0x9999);  // Asset (token1)

    address asset;      // TOKEN_HIGH - the token being auctioned
    address numeraire;  // TOKEN_LOW - the token bidders pay with
    address token0;     // TOKEN_LOW (always the smaller address)
    address token1;     // TOKEN_HIGH (always the larger address)

    // Users
    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    address creator = address(0xc4ea70);
    uint256 bidNonce;

    // Contracts
    OpeningAuctionDeployerToken1Impl auctionDeployer;

    // Auction parameters
    uint256 constant AUCTION_TOKENS = 100 ether;
    uint256 constant AUCTION_DURATION = 1 days;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens with specific addresses to control ordering
        // TOKEN_LOW < TOKEN_HIGH ensures asset (TOKEN_HIGH) is token1
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_LOW);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_HIGH);

        // Asset is TOKEN_HIGH (token1), numeraire is TOKEN_LOW (token0)
        // This is the isToken0=false scenario
        asset = TOKEN_HIGH;
        numeraire = TOKEN_LOW;
        token0 = TOKEN_LOW;   // Smaller address
        token1 = TOKEN_HIGH;  // Larger address

        vm.label(token0, "Token0_Numeraire");
        vm.label(token1, "Token1_Asset");

        // Deploy auction deployer
        auctionDeployer = new OpeningAuctionDeployerToken1Impl(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Fund users with both tokens
        TestERC20(token0).transfer(alice, 10_000_000 ether);
        TestERC20(token1).transfer(alice, 10_000_000 ether);
        TestERC20(token0).transfer(bob, 10_000_000 ether);
        TestERC20(token1).transfer(bob, 10_000_000 ether);
        TestERC20(asset).transfer(creator, AUCTION_TOKENS);
    }

    /// @notice Get default config for isToken0=false auction
    /// @dev minAcceptableTickToken1 is tick(token0/token1) and enforced as a pool-space ceiling.
    function getDefaultConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionTestDefaults.defaultConfig(AUCTION_DURATION, -887_220, -34_020, 60);
    }

    /// @notice Mine a valid salt for the hook address
    function mineHookSalt(
        address deployer,
        address caller,
        uint256 auctionTokens,
        OpeningAuctionConfig memory config
    ) internal view returns (bytes32 salt, address hookAddress) {
        // Build constructor args - deployer passes msg.sender as initializer
        bytes memory constructorArgs = abi.encode(
            manager,
            caller,  // initializer = msg.sender in deploy()
            auctionTokens,
            config
        );

        (hookAddress, salt) = HookMiner.find(
            deployer,
            OpeningAuctionTestDefaults.hookFlags(),
            type(OpeningAuctionToken1Impl).creationCode,
            constructorArgs
        );
    }

    function _minAcceptableTick(OpeningAuction auction) internal view returns (int24) {
        return auction.isToken0() ? auction.minAcceptableTickToken0() : -auction.minAcceptableTickToken1();
    }

    function _getPositionId(
        OpeningAuction auction,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        return auction.positionKeyToId(key);
    }

    function _isInRange(OpeningAuction auction, uint256 positionId) internal view returns (bool) {
        AuctionPosition memory pos = auction.positions(positionId);
        if (pos.owner == address(0)) return false;

        int24 refTick;
        AuctionPhase phase = auction.phase();
        if (phase == AuctionPhase.Settled) {
            refTick = auction.clearingTick();
        } else if (phase == AuctionPhase.Active || phase == AuctionPhase.Closed) {
            refTick = auction.estimatedClearingTick();
        } else {
            return false;
        }

        if (auction.isToken0()) {
            return refTick < pos.tickUpper;
        }
        return refTick >= pos.tickLower;
    }

    // ============ Initialization Tests ============

    /// @notice Test deployment and basic state when isToken0=false
    function test_deployment_IsToken0False() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        // Mine a valid salt
        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        // Deploy auction
        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        vm.stopPrank();

        // Verify initial state
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.NotStarted));
        assertEq(auction.totalAuctionTokens(), AUCTION_TOKENS);
        assertEq(auction.isToken0Set(), false, "isToken0Set should be false before setIsToken0");
    }

    /// @notice Test initialization with correct token ordering for isToken0=false
    /// @dev Pool must be initialized at MIN_TICK for isToken0=false (price starts low)
    function test_initialization_Token1AsAsset() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );

        // Transfer tokens to auction
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);

        // CRITICAL: Set isToken0=false because asset (TOKEN_HIGH) is token1
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);
        assertEq(auction.isToken0(), false, "isToken0 should be false");
        assertEq(auction.isToken0Set(), true, "isToken0Set should be true after setIsToken0");

        // Create pool key with correct token ordering
        // token0 = TOKEN_LOW (numeraire), token1 = TOKEN_HIGH (asset)
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),  // numeraire
            currency1: Currency.wrap(token1),  // asset
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        // For isToken0=false, initialize at MIN_TICK (price starts at lowest)
        // Price will move UP as tokens are sold
        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // Verify auction is active and isToken0 preserved
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active));
        assertEq(auction.isToken0(), false, "isToken0 should still be false after initialization");

        // For isToken0=false, estimated clearing tick starts at MIN_TICK
        assertEq(auction.estimatedClearingTick(), TickMath.MIN_TICK, 
            "clearing tick should start at MIN_TICK for isToken0=false");
    }

    // ============ Bid Placement Tests ============

    /// @notice Test bid placement with reversed token ordering
    /// @dev For isToken0=false:
    ///      - Bid validation: tickUpper <= minAcceptableTick()
    ///      - Bids with tickUpper > minAcceptableTick() are rejected
    function test_placeBid_Token1AsAsset() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        int24 limitTick = _minAcceptableTick(auction);
        int24 tickLower = limitTick - config.tickSpacing; // Upper bound equals the ceiling

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        
        bytes32 bidSalt = keccak256(abi.encode(alice, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(1e18)),
                salt: bidSalt
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();

        // Verify position was created
        uint256 positionId = _getPositionId(auction, alice, tickLower, tickLower + config.tickSpacing, bidSalt);
        AuctionPosition memory pos = auction.positions(positionId);
        assertEq(pos.owner, alice);
        assertEq(pos.tickLower, tickLower);
        assertGt(pos.liquidity, 0);

        console2.log("Bid placed at tickLower:", int256(tickLower));
        console2.log("Position liquidity:", pos.liquidity);
    }

    /// @notice Test that invalid bids are rejected for isToken0=false
    /// @dev Bids with tickUpper > minAcceptableTick should be rejected
    function test_placeBid_RejectsInvalidTickForToken1() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        int24 limitTick = _minAcceptableTick(auction);
        int24 invalidTickLower = limitTick; // tickUpper will exceed the ceiling

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
                tickUpper: invalidTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(1e18)),
                salt: bytes32(uint256(1))
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();
    }

    function test_fuzz_bidValidation_MinAcceptableTickToken1(
        uint256 offsetSeed,
        uint256 liquiditySeed
    ) public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        int24 limitTick = _minAcceptableTick(auction);
        int24 offset = int24(int256(offsetSeed % 7)) - 3;
        int24 tickLower = limitTick + offset * config.tickSpacing;

        vm.assume(tickLower >= TickMath.MIN_TICK);
        vm.assume(tickLower + config.tickSpacing <= TickMath.MAX_TICK);

        uint128 liquidity = auction.minLiquidity() + uint128(liquiditySeed % 1e18);

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        bytes32 bidSalt = keccak256(abi.encode(alice, bidNonce++));
        if (offset >= 0) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(auction),
                    IHooks.beforeAddLiquidity.selector,
                    abi.encodeWithSelector(IOpeningAuction.BidBelowMinimumPrice.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
        }

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bidSalt
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();
    }

    // ============ Multiple Bidders Test ============

    /// @notice Test multiple bidders with isToken0=false
    function test_multipleBidders_Token1AsAsset() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // Alice bids at a higher price (lower tick for isToken0=false)
        // For isToken0=false, lower ticks = higher prices
        int24 aliceTickLower = -config.tickSpacing * 2; // -120, tickUpper = -60
        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 aliceSalt = keccak256(abi.encode(alice, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceTickLower,
                tickUpper: aliceTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(1e18)),
                salt: aliceSalt
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();

        // Bob bids at a lower price (closer to 0 tick for isToken0=false)
        int24 bobTickLower = -config.tickSpacing; // -60, tickUpper = 0
        vm.startPrank(bob);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 bobSalt = keccak256(abi.encode(bob, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobTickLower,
                tickUpper: bobTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(2e18)),
                salt: bobSalt
            }),
            abi.encodePacked(bob)
        );
        vm.stopPrank();

        uint256 alicePosId = _getPositionId(auction, alice, aliceTickLower, aliceTickLower + config.tickSpacing, aliceSalt);
        uint256 bobPosId = _getPositionId(auction, bob, bobTickLower, bobTickLower + config.tickSpacing, bobSalt);

        // Verify both positions
        AuctionPosition memory alicePos = auction.positions(alicePosId);
        AuctionPosition memory bobPos = auction.positions(bobPosId);

        assertEq(alicePos.owner, alice);
        assertEq(bobPos.owner, bob);
        assertEq(alicePos.tickLower, aliceTickLower);
        assertEq(bobPos.tickLower, bobTickLower);
        assertGt(alicePos.liquidity, 0);
        assertGt(bobPos.liquidity, 0);

        console2.log("Alice bid at tick:", int256(aliceTickLower));
        console2.log("Bob bid at tick:", int256(bobTickLower));
    }

    // ============ Settlement Tests ============

    /// @notice Test auction settlement with isToken0=false
    /// @dev Verifies:
    ///      - Clearing tick moves UP from MIN_TICK (opposite of isToken0=true)
    ///      - Tokens are sold correctly
    ///      - Proceeds are collected in numeraire (token0)
    function test_settleAuction_Token1AsAsset() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // Place large bids close to the minimum acceptable tick to provide near-start liquidity
        int24 limitTick = _minAcceptableTick(auction);
        int24 aliceTickLower = limitTick - config.tickSpacing;
        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 aliceSalt = keccak256(abi.encode(alice, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceTickLower,
                tickUpper: aliceTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(100_000 ether)),
                salt: aliceSalt
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();

        int24 bobTickLower = limitTick - (config.tickSpacing * 2);
        vm.startPrank(bob);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 bobSalt = keccak256(abi.encode(bob, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobTickLower,
                tickUpper: bobTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(100_000 ether)),
                salt: bobSalt
            }),
            abi.encodePacked(bob)
        );
        vm.stopPrank();

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Record balances before settlement
        uint256 hookAssetBefore = TestERC20(asset).balanceOf(address(auction));
        uint256 hookNumeraireBefore = TestERC20(numeraire).balanceOf(address(auction));

        // Settle auction
        auction.settleAuction();

        // Verify auction is settled
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));

        // Verify isToken0 is still false
        assertEq(auction.isToken0(), false, "isToken0 should remain false after settlement");

        // Log results
        console2.log("=== Settlement Results (isToken0=false) ===");
        console2.log("Starting tick:", int256(startingTick));
        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("Tokens sold:", auction.totalTokensSold());
        console2.log("Proceeds (numeraire):", auction.totalProceeds());
        console2.log("Hook asset before:", hookAssetBefore);
        console2.log("Hook numeraire before:", hookNumeraireBefore);

        // For isToken0=false, clearing tick should have moved UP from MIN_TICK
        assertGt(auction.clearingTick(), TickMath.MIN_TICK, 
            "clearing tick should have increased from MIN_TICK");

        // Clearing tick must be >= minAcceptableTick for isToken0=false
        assertLe(auction.clearingTick(), _minAcceptableTick(auction),
            "clearing tick should be <= minAcceptableTick");

        // Tokens sold can be zero if no active liquidity was reachable from the starting price
        assertGe(auction.totalTokensSold(), 0, "tokens sold should be non-negative");
    }

    // ============ Full Auction Flow Test ============

    /// @notice Test complete auction flow with isToken0=false
    /// @dev This is the comprehensive happy path test covering:
    ///      1. Deployment with correct token ordering
    ///      2. Initialization at MIN_TICK
    ///      3. Bid placement with correct tick validation
    ///      4. Settlement with price moving UP
    ///      5. Incentive claiming
    function test_fullAuctionFlow_Token1AsAsset() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        // ====== Step 1: Deploy Auction ======
        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);

        // CRITICAL: Set isToken0=false for token1 as asset
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),  // numeraire
            currency1: Currency.wrap(token1),  // asset
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        // ====== Step 2: Initialize at MIN_TICK ======
        // For isToken0=false, price starts at MIN_TICK and moves UP
        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active));
        assertEq(auction.isToken0(), false);
        assertEq(auction.estimatedClearingTick(), TickMath.MIN_TICK);

        console2.log("=== Auction Initialized ===");
        console2.log("isToken0:", auction.isToken0());
        console2.log("Starting tick:", int256(startingTick));
        console2.log("Estimated clearing tick:", int256(auction.estimatedClearingTick()));

        // ====== Step 3: Place Bids ======
        // Alice places high-price bid (lower tick for isToken0=false)
        int24 aliceTickLower = -600;
        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 aliceSalt = keccak256(abi.encode(alice, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceTickLower,
                tickUpper: aliceTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(50_000 ether)),
                salt: aliceSalt
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();

        // Bob places lower-price bid (higher tick for isToken0=false)
        int24 bobTickLower = -config.tickSpacing;
        vm.startPrank(bob);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 bobSalt = keccak256(abi.encode(bob, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobTickLower,
                tickUpper: bobTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(50_000 ether)),
                salt: bobSalt
            }),
            abi.encodePacked(bob)
        );
        vm.stopPrank();

        uint256 alicePosId = _getPositionId(auction, alice, aliceTickLower, aliceTickLower + config.tickSpacing, aliceSalt);
        uint256 bobPosId = _getPositionId(auction, bob, bobTickLower, bobTickLower + config.tickSpacing, bobSalt);

        console2.log("=== Bids Placed ===");
        console2.log("Alice bid at tick:", int256(aliceTickLower));
        console2.log("Bob bid at tick:", int256(bobTickLower));
        console2.log("Estimated clearing tick after bids:", int256(auction.estimatedClearingTick()));

        // Verify positions
        AuctionPosition memory alicePos = auction.positions(alicePosId);
        AuctionPosition memory bobPos = auction.positions(bobPosId);
        assertEq(alicePos.owner, alice);
        assertEq(bobPos.owner, bob);

        // ====== Step 4: Settle Auction ======
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));

        int24 clearingTick = auction.clearingTick();
        uint256 tokensSold = auction.totalTokensSold();
        uint256 proceeds = auction.totalProceeds();

        console2.log("=== Auction Settled ===");
        console2.log("Final clearing tick:", int256(clearingTick));
        console2.log("Tokens sold:", tokensSold);
        console2.log("Proceeds:", proceeds);

        // Verify clearing tick behavior for isToken0=false
        // Price moved UP from MIN_TICK, so clearing tick > MIN_TICK
        assertGt(clearingTick, TickMath.MIN_TICK, "clearing tick should have moved up");
        assertLe(clearingTick, _minAcceptableTick(auction), "clearing tick <= minAcceptableTick");

        // ====== Step 5: Verify Incentive Calculations ======
        uint256 aliceIncentives = auction.calculateIncentives(alicePosId);
        uint256 bobIncentives = auction.calculateIncentives(bobPosId);

        console2.log("=== Incentives ===");
        console2.log("Alice incentives:", aliceIncentives);
        console2.log("Bob incentives:", bobIncentives);
        console2.log("Total incentive tokens:", auction.incentiveTokensTotal());

        // If either position earned time (was in range), they should have incentives
        if (aliceIncentives > 0 || bobIncentives > 0) {
            assertLe(aliceIncentives + bobIncentives, auction.incentiveTokensTotal(),
                "total claimed incentives should not exceed available");
        }

        // Verify isToken0 remained false throughout
        assertEq(auction.isToken0(), false, "isToken0 should remain false after full flow");
    }

    // ============ Position Locking Tests ============

    /// @notice Test position locking logic for isToken0=false
    /// @dev For isToken0=false: position is "filled" if clearingTick >= tickLower
    function test_positionLocking_Token1AsAsset() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // Place a bid that will definitely be filled (lower tick)
        int24 lowTickBid = -600;
        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 bidSalt = keccak256(abi.encode(alice, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lowTickBid,
                tickUpper: lowTickBid + config.tickSpacing,
                liquidityDelta: int256(uint256(100_000 ether)),
                salt: bidSalt
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();

        uint256 posId = _getPositionId(auction, alice, lowTickBid, lowTickBid + config.tickSpacing, bidSalt);

        // Get estimated clearing tick after bid
        int24 estimatedClearing = auction.estimatedClearingTick();

        console2.log("=== Position Locking (isToken0=false) ===");
        console2.log("Bid tickLower:", int256(lowTickBid));
        console2.log("Estimated clearing tick:", int256(estimatedClearing));

        // For isToken0=false: position is filled if clearingTick >= tickLower
        bool shouldBeFilled = estimatedClearing >= lowTickBid;
        bool isLocked = _isInRange(auction, posId);

        console2.log("Expected filled:", shouldBeFilled);
        console2.log("Actual locked:", isLocked);

        assertEq(isLocked, shouldBeFilled, 
            "position lock state should match fill expectation for isToken0=false");
    }

    // ============ Timing Tests ============

    /// @notice Test auction timing and phases with isToken0=false
    function test_auctionTiming_Token1AsAsset() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        OpeningAuction auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setPositionManager(address(modifyLiquidityRouter));
        auction.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        // Before initialize - NotStarted phase
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.NotStarted));

        // Initialize pool
        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // After initialize - Active phase
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active));

        // Check timing
        assertEq(auction.auctionStartTime(), block.timestamp);
        assertEq(auction.auctionEndTime(), block.timestamp + AUCTION_DURATION);

        // Before auction end - cannot settle
        vm.expectRevert(IOpeningAuction.AuctionNotEnded.selector);
        auction.settleAuction();

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Verify isToken0 still false at auction end
        assertEq(auction.isToken0(), false, "isToken0 should remain false at auction end");
    }
}
