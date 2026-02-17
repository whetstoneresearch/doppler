// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase } from "src/interfaces/IOpeningAuction.sol";
import {
    OpeningAuctionInitializer,
    OpeningAuctionDeployer,
    OpeningAuctionInitData,
    OpeningAuctionStatus,
    IDopplerDeployer,
    AssetAlreadyInitialized,
    DopplerNotActive,
    InvalidTokenOrder,
    InvalidExitTarget,
    IsToken0Mismatch
} from "src/OpeningAuctionInitializer.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { DopplerDeployer } from "src/initializers/UniswapV4Initializer.sol";
import { alignTickTowardZero, alignTick } from "src/libraries/TickLibrary.sol";
import { OpeningAuctionTestDefaults } from "test/shared/OpeningAuctionTestDefaults.sol";

struct DopplerData {
    uint256 minimumProceeds;
    uint256 maximumProceeds;
    uint256 startingTime;
    uint256 endingTime;
    int24 startingTick;
    int24 endingTick;
    uint256 epochLength;
    int24 gamma;
    bool isToken0;
    uint256 numPDSlugs;
    uint24 lpFee;
    int24 tickSpacing;
}

/// @title OpeningAuctionInitializerTest
/// @notice Unit tests for OpeningAuctionInitializer validation and state transitions
contract OpeningAuctionInitializerTest is Test, Deployers {
    // Tokens
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;
    address token0;
    address token1;

    // Contracts
    OpeningAuctionInitializer initializer;
    OpeningAuctionDeployer auctionDeployer;
    DopplerDeployer dopplerDeployer;

    // Test parameters
    uint256 constant AUCTION_TOKENS = 100 ether;
    uint256 constant AUCTION_DURATION = 1 days;

    // Users
    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    address airlock;
    address governance;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(asset, "Asset");
        vm.label(numeraire, "Numeraire");
        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        // Use this test contract as the airlock
        airlock = address(this);
        governance = makeAddr("Governance");

        // Deploy deployers
        auctionDeployer = new OpeningAuctionDeployer(manager);
        dopplerDeployer = new DopplerDeployer(manager);

        // Deploy modify liquidity router
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");

        // Deploy initializer with this contract as airlock
        initializer = new OpeningAuctionInitializer(
            airlock,
            manager,
            auctionDeployer,
            IDopplerDeployer(address(dopplerDeployer)),
            address(modifyLiquidityRouter)
        );
        vm.label(address(initializer), "Initializer");

        // Approve initializer to spend tokens
        TestERC20(asset).approve(address(initializer), type(uint256).max);
        TestERC20(numeraire).approve(address(initializer), type(uint256).max);

        // Fund users
        TestERC20(token0).transfer(alice, 10_000_000 ether);
        TestERC20(token1).transfer(alice, 10_000_000 ether);
        TestERC20(token0).transfer(bob, 10_000_000 ether);
        TestERC20(token1).transfer(bob, 10_000_000 ether);
    }

    /// @notice Mine a valid salt for the hook address
    function mineHookSalt(
        uint256 auctionTokens,
        OpeningAuctionConfig memory config
    ) internal returns (bytes32 salt) {
        // Build constructor args - deployer passes initializer (msg.sender) as the initializer
        bytes memory constructorArgs = abi.encode(
            manager,
            address(initializer),  // initializer = msg.sender in deploy()
            auctionTokens,
            config
        );

        (,salt) = HookMiner.find(
            address(auctionDeployer),
            OpeningAuctionTestDefaults.hookFlags(),
            type(OpeningAuction).creationCode,
            constructorArgs
        );
    }

    /// @notice Create default auction config
    function getDefaultAuctionConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionTestDefaults.defaultConfig(AUCTION_DURATION, -34_020, -34_020, 60);
    }

    /// @notice Create Doppler data
    function getDopplerData(int24 dopplerTickSpacing, bool isToken0) internal view returns (bytes memory) {
        return abi.encode(
            uint256(0),               // minimumProceeds
            uint256(1e30),            // maximumProceeds
            block.timestamp + 1 days, // startingTime (after auction ends)
            block.timestamp + 8 days, // endingTime
            int24(0),                 // startingTick (will be overwritten)
            int24(-100_000),          // endingTick
            uint256(1 hours),         // epochLength
            int24(180),               // gamma
            isToken0,                 // isToken0
            uint256(5),               // numPDSlugs
            uint24(3000),             // lpFee
            dopplerTickSpacing        // tickSpacing
        );
    }

    /// @notice Create init data for the initializer
    function getInitData(int24 dopplerTickSpacing) internal view returns (OpeningAuctionInitData memory) {
        bool isToken0 = asset < numeraire;
        return OpeningAuctionInitData({
            auctionConfig: getDefaultAuctionConfig(),
            dopplerData: getDopplerData(dopplerTickSpacing, isToken0)
        });
    }

    function test_initialize_splitsTokens_correctly() public {
        OpeningAuctionInitData memory initData = getInitData(30);
        initData.auctionConfig.shareToAuctionBps = 2500; // 25%

        uint256 expectedAuctionTokens = (AUCTION_TOKENS * 2500) / 10_000;
        bytes32 salt = mineHookSalt(expectedAuctionTokens, initData.auctionConfig);
        uint256 airlockBalanceBefore = TestERC20(asset).balanceOf(address(this));

        address auctionHookAddr = initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt,
            abi.encode(initData)
        );

        (
            ,
            ,
            ,
            uint256 auctionTokens,
            uint256 dopplerTokens,
            ,
            ,
            ,
            ,
            ,
            
        ) = initializer.getState(asset);
        uint256 expectedDopplerTokens = AUCTION_TOKENS - expectedAuctionTokens;

        assertEq(auctionTokens, expectedAuctionTokens);
        assertEq(dopplerTokens, expectedDopplerTokens);
        assertEq(TestERC20(asset).balanceOf(auctionHookAddr), AUCTION_TOKENS);
        assertEq(TestERC20(asset).balanceOf(address(this)), airlockBalanceBefore - AUCTION_TOKENS);
    }

    /* -------------------------------------------------------------------------- */
    /*                         completeAuction Tests                               */
    /* -------------------------------------------------------------------------- */

    /// @notice Test that completeAuction succeeds with a mined Doppler salt
    function test_completeAuction_SucceedsWithMinedSalt() public {
        OpeningAuctionConfig memory config = getDefaultAuctionConfig();
        OpeningAuctionInitData memory initData = getInitData(30);
        
        // Mine a valid salt for the hook
        bytes32 salt = mineHookSalt(AUCTION_TOKENS, config);
        
        // Initialize auction
        address auctionHookAddr = initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt,
            abi.encode(initData)
        );
        
        OpeningAuction auctionHook = OpeningAuction(payable(auctionHookAddr));
        
        // Get pool key from hook
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = auctionHook.poolKey();
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
        
        // Place bids at a high tick to ensure clearing price is good
        int24 tickLower = 0;
        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + poolKey.tickSpacing,
                liquidityDelta: int256(uint256(100_000 ether)),
                salt: bytes32(uint256(1))
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();
        
        // Warp to auction end
        vm.warp(auctionHook.auctionEndTime() + 1);
        
        // Settle auction
        auctionHook.settleAuction();
        
        // Get proceeds amount (should be non-zero after settlement)
        uint256 proceeds = auctionHook.totalProceeds();
        console2.log("Total proceeds from auction:", proceeds);
        assertGt(proceeds, 0, "Should have proceeds after settlement");
        
        // Verify the hook has numeraire (proceeds) after settlement
        uint256 hookNumeraireBalance = TestERC20(numeraire).balanceOf(auctionHookAddr);
        assertEq(hookNumeraireBalance, proceeds, "Hook should hold proceeds after settlement");
        
        DopplerData memory decoded = abi.decode(initData.dopplerData, (DopplerData));
        int24 alignedClearingTick =
            _alignClearingTick(auctionHook.isToken0(), auctionHook.clearingTick(), decoded.tickSpacing);
        bytes32 dopplerSalt = _mineDopplerSalt(auctionHook, initData.dopplerData, alignedClearingTick);

        initializer.completeAuction(asset, dopplerSalt);

        (
            ,
            ,
            ,
            ,
            ,
            OpeningAuctionStatus statusAfter,
            ,
            address dopplerHook,
            ,
            ,
            
        ) = initializer.getState(asset);
        assertEq(uint8(statusAfter), uint8(OpeningAuctionStatus.DopplerActive));
        assertTrue(dopplerHook != address(0), "Doppler hook should be set");
    }

    /// @notice Test that completeAuction reverts with an invalid Doppler salt
    /// @dev Proceeds forwarding is covered in integration tests with valid hook addresses.
    function test_completeAuction_RevertsWithInvalidDopplerSalt() public {
        OpeningAuctionConfig memory config = getDefaultAuctionConfig();
        OpeningAuctionInitData memory initData = getInitData(30);

        bytes32 salt = mineHookSalt(AUCTION_TOKENS, config);

        address auctionHookAddr = initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt,
            abi.encode(initData)
        );

        OpeningAuction auctionHook = OpeningAuction(payable(auctionHookAddr));

        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = auctionHook.poolKey();
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });

        int24 tickLower = 0;
        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + poolKey.tickSpacing,
                liquidityDelta: int256(uint256(100_000 ether)),
                salt: bytes32(uint256(1))
            }),
            abi.encodePacked(alice)
        );
        vm.stopPrank();

        vm.warp(auctionHook.auctionEndTime() + 1);
        auctionHook.settleAuction();

        DopplerData memory decoded = abi.decode(initData.dopplerData, (DopplerData));
        int24 alignedClearingTick =
            _alignClearingTick(auctionHook.isToken0(), auctionHook.clearingTick(), decoded.tickSpacing);
        bytes32 invalidSalt = _findInvalidDopplerSalt(auctionHook, initData.dopplerData, alignedClearingTick);
        (bytes memory constructorArgs,) =
            _buildDopplerConstructorArgs(auctionHook, initData.dopplerData, alignedClearingTick);
        bytes memory creationCodeWithArgs = abi.encodePacked(type(Doppler).creationCode, constructorArgs);
        address expectedHook =
            HookMiner.computeAddress(address(dopplerDeployer), uint256(invalidSalt), creationCodeWithArgs);

        (
            ,
            ,
            ,
            ,
            ,
            OpeningAuctionStatus statusBefore,
            ,
            ,
            ,
            ,
            
        ) = initializer.getState(asset);

        vm.expectRevert(
            abi.encodeWithSelector(
                DopplerDeployer.InvalidDopplerSalt.selector,
                invalidSalt,
                expectedHook
            )
        );
        initializer.completeAuction(asset, invalidSalt);

        (
            ,
            ,
            ,
            ,
            ,
            OpeningAuctionStatus statusAfter,
            ,
            ,
            ,
            ,
            
        ) = initializer.getState(asset);
        assertEq(uint8(statusAfter), uint8(statusBefore));
    }

    function getAssetData(address)
        external
        view
        returns (
            address assetNumeraire,
            address timelock,
            address governance_,
            address liquidityMigrator,
            address poolInitializer,
            address pool,
            address migrationPool,
            uint256 numTokensToSell,
            uint256 totalSupply,
            address integrator
        )
    {
        return (numeraire, address(0), governance, address(0), address(0), address(0), address(0), 0, 0, address(0));
    }

    /* -------------------------------------------------------------------------- */
    /*                         initialize Validation Tests                         */
    /* -------------------------------------------------------------------------- */

    /// @notice Test that initialize reverts when same asset is initialized twice
    /// @dev Prevents orphaning of first auction hook and ensures single active auction per asset
    function test_initialize_revertsWhenAssetAlreadyInitialized() public {
        OpeningAuctionConfig memory config = getDefaultAuctionConfig();
        OpeningAuctionInitData memory initData = getInitData(30);
        
        // Mine salt for first init
        bytes32 salt1 = mineHookSalt(AUCTION_TOKENS, config);
        
        // First initialization succeeds
        address firstHook = initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt1,
            abi.encode(initData)
        );
        assertTrue(firstHook != address(0), "First init should succeed");
        
        // Fund again for second init attempt
        TestERC20(asset).transfer(address(this), AUCTION_TOKENS);
        
        // Mine different salt for second init
        bytes32 salt2 = mineHookSalt(AUCTION_TOKENS, config);
        if (salt2 == salt1) {
            salt2 = bytes32(uint256(salt2) + 1);
        }
        
        // Second initialization with same asset should revert
        vm.expectRevert(AssetAlreadyInitialized.selector);
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt2,
            abi.encode(initData)
        );
    }

    /// @notice Test that initialize reverts when asset and numeraire are the same
    function test_initialize_revertsWhenAssetEqualsNumeraire() public {
        OpeningAuctionConfig memory config = getDefaultAuctionConfig();
        OpeningAuctionInitData memory initData = getInitData(30);
        bytes32 salt = mineHookSalt(AUCTION_TOKENS, config);

        vm.expectRevert(InvalidTokenOrder.selector);
        initializer.initialize(
            asset,
            asset,
            AUCTION_TOKENS,
            salt,
            abi.encode(initData)
        );
    }

    /// @notice Test that initialize reverts when dopplerData.isToken0 doesn't match token ordering
    /// @dev Prevents misconfiguration where wrong token would be sold in Doppler phase
    function test_initialize_revertsOnIsToken0Mismatch() public {
        bool correctIsToken0 = asset < numeraire;
        bool wrongIsToken0 = !correctIsToken0;
        
        // Create doppler data with WRONG isToken0
        bytes memory wrongDopplerData = abi.encode(
            uint256(0),               // minimumProceeds
            uint256(1e30),            // maximumProceeds
            block.timestamp + 1 days, // startingTime
            block.timestamp + 8 days, // endingTime
            int24(0),                 // startingTick
            int24(-100_000),          // endingTick
            uint256(1 hours),         // epochLength
            int24(60),                // gamma
            wrongIsToken0,            // WRONG isToken0
            uint256(5),               // numPDSlugs
            uint24(3000),             // lpFee
            int24(60)                 // tickSpacing
        );
        
        OpeningAuctionInitData memory initData = OpeningAuctionInitData({
            auctionConfig: getDefaultAuctionConfig(),
            dopplerData: wrongDopplerData
        });
        
        bytes32 salt = mineHookSalt(AUCTION_TOKENS, getDefaultAuctionConfig());
        
        vm.expectRevert(IsToken0Mismatch.selector);
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt,
            abi.encode(initData)
        );
    }

    /// @notice Test exitLiquidity reverts when auction is still active (not transitioned to Doppler)
    function test_exitLiquidity_revertsWhenAuctionActive() public {
        OpeningAuctionInitData memory initData = getInitData(30);
        bytes32 salt = mineHookSalt(AUCTION_TOKENS, initData.auctionConfig);
        
        // Initialize auction
        address auctionHook = initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt,
            abi.encode(initData)
        );
        
        // Try to exit liquidity while auction is still active
        // This should fail because status is AuctionActive, not DopplerActive
        vm.expectRevert(DopplerNotActive.selector);
        initializer.exitLiquidity(auctionHook); // Wrong target - auction hook, not doppler
    }

    /// @notice Test exitLiquidity reverts when called with invalid target
    function test_exitLiquidity_revertsWithInvalidTarget() public {
        OpeningAuctionInitData memory initData = getInitData(30);
        bytes32 salt = mineHookSalt(AUCTION_TOKENS, initData.auctionConfig);
        
        // Initialize auction
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt,
            abi.encode(initData)
        );
        
        // Try to exit liquidity with random address
        address randomTarget = address(0x1234);
        vm.expectRevert(InvalidExitTarget.selector);
        initializer.exitLiquidity(randomTarget);
    }

    /// @notice Test state transitions are correctly tracked
    function test_stateTransitions_auctionToSettled() public {
        OpeningAuctionInitData memory initData = getInitData(30);
        bytes32 salt = mineHookSalt(AUCTION_TOKENS, initData.auctionConfig);
        
        // Initialize auction
        address auctionHook = initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            salt,
            abi.encode(initData)
        );
        
        // Verify state after initialization using helper functions
        assertEq(initializer.getOpeningAuctionHook(asset), auctionHook, "Auction hook should be set");
        assertEq(initializer.getDopplerHook(asset), address(0), "Doppler hook should not be set yet");
        
        // Verify auction hook is properly configured
        OpeningAuction auction = OpeningAuction(payable(auctionHook));
        assertEq(uint256(auction.phase()), uint256(AuctionPhase.Active), "Auction should be active");
    }

    /// @notice Test that getState returns correct values for uninitialized asset
    function test_getState_uninitializedAsset() public view {
        address uninitializedAsset = address(0x9999);
        
        // For uninitialized assets, helper functions should return zero addresses
        assertEq(initializer.getOpeningAuctionHook(uninitializedAsset), address(0), "Auction hook should be zero");
        assertEq(initializer.getDopplerHook(uninitializedAsset), address(0), "Doppler hook should be zero");
    }

    function _mineDopplerSalt(
        OpeningAuction auctionHook,
        bytes memory dopplerData,
        int24 alignedClearingTick
    ) internal returns (bytes32) {
        (bytes memory constructorArgs,) = _buildDopplerConstructorArgs(auctionHook, dopplerData, alignedClearingTick);
        (, bytes32 salt) = HookMiner.find(
            address(dopplerDeployer),
            _dopplerHookFlags(),
            type(Doppler).creationCode,
            constructorArgs
        );
        return salt;
    }

    function _findInvalidDopplerSalt(
        OpeningAuction auctionHook,
        bytes memory dopplerData,
        int24 alignedClearingTick
    ) internal returns (bytes32) {
        (bytes memory constructorArgs,) = _buildDopplerConstructorArgs(auctionHook, dopplerData, alignedClearingTick);
        bytes memory creationCodeWithArgs = abi.encodePacked(type(Doppler).creationCode, constructorArgs);

        for (uint256 salt; ; ++salt) {
            address hook = HookMiner.computeAddress(address(dopplerDeployer), salt, creationCodeWithArgs);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK != _dopplerHookFlags() && hook.code.length == 0) {
                return bytes32(salt);
            }
        }
        revert("invalid doppler salt not found");
    }

    function _buildDopplerConstructorArgs(
        OpeningAuction auctionHook,
        bytes memory dopplerData,
        int24 alignedClearingTick
    ) internal returns (bytes memory constructorArgs, DopplerData memory decoded) {
        bytes memory modifiedData = _modifyDopplerStartingTick(dopplerData, alignedClearingTick);
        decoded = abi.decode(modifiedData, (DopplerData));

        uint256 unsoldTokens =
            auctionHook.totalAuctionTokens() - auctionHook.incentiveTokensTotal() - auctionHook.totalTokensSold();

        constructorArgs = abi.encode(
            manager,
            unsoldTokens,
            decoded.minimumProceeds,
            decoded.maximumProceeds,
            decoded.startingTime,
            decoded.endingTime,
            decoded.startingTick,
            decoded.endingTick,
            decoded.epochLength,
            decoded.gamma,
            decoded.isToken0,
            decoded.numPDSlugs,
            address(initializer),
            decoded.lpFee
        );
    }

    function _modifyDopplerStartingTick(bytes memory dopplerData, int24 newStartingTick)
        internal
        view
        returns (bytes memory)
    {
        DopplerData memory decoded = abi.decode(dopplerData, (DopplerData));

        uint256 originalDuration = decoded.endingTime - decoded.startingTime;

        uint256 newStartingTime = decoded.startingTime;
        uint256 newEndingTime = decoded.endingTime;
        if (block.timestamp >= decoded.startingTime) {
            newStartingTime = block.timestamp + 1;
            newEndingTime = newStartingTime + originalDuration;
        }

        return abi.encode(
            decoded.minimumProceeds,
            decoded.maximumProceeds,
            newStartingTime,
            newEndingTime,
            newStartingTick,
            decoded.endingTick,
            decoded.epochLength,
            decoded.gamma,
            decoded.isToken0,
            decoded.numPDSlugs,
            decoded.lpFee,
            decoded.tickSpacing
        );
    }

    function _alignClearingTick(bool isToken0, int24 clearingTick, int24 tickSpacing)
        internal
        pure
        returns (int24)
    {
        int24 aligned = alignTick(isToken0, clearingTick, tickSpacing);
        int24 minAligned = alignTickTowardZero(TickMath.MIN_TICK, tickSpacing);
        int24 maxAligned = alignTickTowardZero(TickMath.MAX_TICK, tickSpacing);
        if (aligned < minAligned) {
            aligned = minAligned;
        }
        if (aligned > maxAligned) {
            aligned = maxAligned;
        }
        return aligned;
    }

    function _dopplerHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_DONATE_FLAG
        );
    }
}
