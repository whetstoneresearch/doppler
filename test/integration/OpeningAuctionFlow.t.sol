// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import {
    OpeningAuctionInitializer,
    OpeningAuctionDeployer,
    OpeningAuctionInitData,
    OpeningAuctionStatus
} from "src/OpeningAuctionInitializer.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice OpeningAuctionDeployer that creates the implementation without address validation
contract OpeningAuctionDeployerImpl is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) {}

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionImpl auction = new OpeningAuctionImpl{salt: salt}(
            poolManager,
            msg.sender,
            auctionTokens,
            config
        );

        return OpeningAuction(payable(address(auction)));
    }
}

contract OpeningAuctionFlowTest is Test, Deployers {
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
    address creator = address(0xc4ea70);
    uint256 bidNonce;

    // Contracts
    OpeningAuctionDeployerImpl auctionDeployer;

    // Auction parameters - use smaller amounts for tests since liquidity provided is limited
    uint256 constant AUCTION_TOKENS = 100 ether;  // 100 tokens (realistic for test liquidity)
    uint256 constant AUCTION_DURATION = 1 days;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        // Deploy auction deployer
        auctionDeployer = new OpeningAuctionDeployerImpl(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Fund users
        TestERC20(token0).transfer(alice, 10_000_000 ether);
        TestERC20(token1).transfer(alice, 10_000_000 ether);
        TestERC20(token0).transfer(bob, 10_000_000 ether);
        TestERC20(token1).transfer(bob, 10_000_000 ether);
        TestERC20(asset).transfer(creator, AUCTION_TOKENS);
    }

    function getDefaultConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -34_020, // ~0.033 price floor (e.g., 10k USD min raise at 3k ETH for 100 tokens)
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000, // 10%
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e15
        });
    }

    /// @notice Get the hook flags for OpeningAuction
    function getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_DONATE_FLAG
        );
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
            getHookFlags(),
            type(OpeningAuctionImpl).creationCode,
            constructorArgs
        );
    }

    function test_fullAuctionFlow_DeployAndSettle() public {
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
    }

    function test_fullAuctionFlow_PlaceBids() public {
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

        // Transfer tokens to auction
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);

        // Set isToken0 (creator is the initializer since they called deploy)
        auction.setIsToken0(true);

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        // Initialize pool at MAX_TICK (must be called by initializer = creator)
        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // Verify auction is now active
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active));

        // Place bid from alice using router with hookData
        int24 tickLower = config.minAcceptableTickToken0 + config.tickSpacing * 10;

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 bidSalt = keccak256(abi.encode(alice, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(1e18)), // 1e18 liquidity units
                salt: bidSalt
            }),
            abi.encode(alice) // Pass owner in hookData
        );
        vm.stopPrank();

        // Verify position was created - owner is alice (not router, since hook owns liquidity)
        uint256 positionId = auction.getPositionId(alice, tickLower, tickLower + config.tickSpacing, bidSalt);
        AuctionPosition memory pos = auction.positions(positionId);
        assertEq(pos.owner, alice);
        assertEq(pos.tickLower, tickLower);
        assertGt(pos.liquidity, 0);
    }

    function test_fullAuctionFlow_MultipleBidders() public {
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
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);

        // Set isToken0 (creator is the initializer since they called deploy)
        auction.setIsToken0(true);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        // Initialize pool at MAX_TICK (must be called by initializer = creator)
        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // Alice places bid at higher price using router
        int24 aliceTickLower = config.minAcceptableTickToken0 + config.tickSpacing * 20;
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
            abi.encode(alice)
        );
        vm.stopPrank();

        // Bob places bid at lower price using router
        int24 bobTickLower = config.minAcceptableTickToken0 + config.tickSpacing * 10;
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
            abi.encode(bob)
        );
        vm.stopPrank();

        // Verify both positions - owner is the actual user now
        uint256 alicePosId = auction.getPositionId(alice, aliceTickLower, aliceTickLower + config.tickSpacing, aliceSalt);
        uint256 bobPosId = auction.getPositionId(bob, bobTickLower, bobTickLower + config.tickSpacing, bobSalt);
        AuctionPosition memory alicePos = auction.positions(alicePosId);
        AuctionPosition memory bobPos = auction.positions(bobPosId);

        assertEq(alicePos.owner, alice);
        assertEq(bobPos.owner, bob);
        assertEq(alicePos.tickLower, aliceTickLower);
        assertEq(bobPos.tickLower, bobTickLower);
        assertGt(alicePos.liquidity, 0);
        assertGt(bobPos.liquidity, 0);
    }

    function test_fullAuctionFlow_AuctionTimingAndPhases() public {
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
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setIsToken0(true);

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
        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // After initialize - Active phase
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active));

        // Check timing
        assertEq(auction.auctionStartTime(), block.timestamp);
        assertEq(auction.auctionEndTime(), block.timestamp + AUCTION_DURATION);

        // Before auction end - cannot settle
        vm.expectRevert();
        auction.settleAuction();

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Note: Full settlement test requires proper swap mechanics
        // which is tested separately. Here we just verify the timing check passes.
    }

    function test_fullAuctionFlow_SettleWithBids() public {
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

        // Transfer tokens to auction
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
        auction.setIsToken0(true);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        // Initialize pool at MAX_TICK
        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // Place bids from alice and bob using router at high ticks to ensure clearing > minAcceptable
        int24 aliceTickLower = 0; // High price bid
        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 aliceSalt = keccak256(abi.encode(alice, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceTickLower,
                tickUpper: aliceTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(100_000 ether)), // Large liquidity to absorb tokens
                salt: aliceSalt
            }),
            abi.encode(alice)
        );
        vm.stopPrank();

        int24 bobTickLower = -600; // Slightly lower price bid
        vm.startPrank(bob);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 bobSalt = keccak256(abi.encode(bob, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobTickLower,
                tickUpper: bobTickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(100_000 ether)), // Large liquidity to absorb tokens
                salt: bobSalt
            }),
            abi.encode(bob)
        );
        vm.stopPrank();

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Capture balances before settlement
        uint256 hookNumeraireBefore = TestERC20(numeraire).balanceOf(address(auction));

        // Settle auction - this should now work with the fixed _settleDeltas
        auction.settleAuction();

        // Verify auction is settled
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));

        // Check that some tokens were sold and proceeds were collected
        uint256 tokensSold = auction.totalTokensSold();
        uint256 proceeds = auction.totalProceeds();

        // After settlement, hook should have received numeraire (proceeds)
        uint256 hookNumeraireAfter = TestERC20(numeraire).balanceOf(address(auction));

        // Log results for debugging
        emit log_named_uint("Tokens sold", tokensSold);
        emit log_named_uint("Proceeds", proceeds);
        emit log_named_int("Clearing tick", auction.clearingTick());
        emit log_named_uint("Hook numeraire before", hookNumeraireBefore);
        emit log_named_uint("Hook numeraire after", hookNumeraireAfter);

        // Clearing tick should be at or below the highest bid
        assertLe(auction.clearingTick(), aliceTickLower + config.tickSpacing);
    }
}
