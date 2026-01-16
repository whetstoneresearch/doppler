// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase } from "src/interfaces/IOpeningAuction.sol";
import {
    OpeningAuctionInitializer,
    OpeningAuctionDeployer,
    OpeningAuctionInitData,
    IDopplerDeployer
} from "src/OpeningAuctionInitializer.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { QuoterMath } from "src/libraries/QuoterMath.sol";
import { alignTick } from "src/libraries/TickLibrary.sol";

using PoolIdLibrary for PoolKey;
using StateLibrary for IPoolManager;

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

contract DopplerDeployerHookMiner is IDopplerDeployer {
    IPoolManager public poolManager;
    bytes32 public nextSalt;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function deploy(uint256 numTokensToSell, bytes32, bytes calldata data) external returns (Doppler) {
        if (nextSalt == bytes32(0)) {
            revert("nextSalt not set");
        }

        DopplerData memory decoded = abi.decode(data, (DopplerData));

        bytes32 salt = nextSalt;
        nextSalt = bytes32(0);

        return new Doppler{salt: salt}(
            poolManager,
            numTokensToSell,
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
            msg.sender,
            decoded.lpFee
        );
    }

    function setNextSalt(bytes32 salt) external {
        nextSalt = salt;
    }
}

contract OpeningAuctionInitializerTickAlignmentTest is Test, Deployers {
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;
    address token0;
    address token1;

    address alice = address(0xa71c3);
    address airlock;
    address governance;
    uint256 bidNonce;

    OpeningAuctionInitializer initializer;
    OpeningAuctionDeployer auctionDeployer;
    DopplerDeployerHookMiner dopplerDeployer;
    function setUp() public {
        manager = new PoolManager(address(this));

        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        airlock = address(this);
        governance = makeAddr("Governance");

        auctionDeployer = new OpeningAuctionDeployer(manager);
        dopplerDeployer = new DopplerDeployerHookMiner(manager);
        initializer = new OpeningAuctionInitializer(airlock, manager, auctionDeployer, dopplerDeployer);

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        TestERC20(asset).approve(address(initializer), type(uint256).max);

        TestERC20(token0).transfer(alice, 10_000_000 ether);
        TestERC20(token1).transfer(alice, 10_000_000 ether);

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_completeAuction_alignsNegativeMisalignedClearingTick() public {
        OpeningAuctionConfig memory config = _getAuctionConfig();
        int24 dopplerTickSpacing = 30;
        OpeningAuctionInitData memory initData = OpeningAuctionInitData({
            auctionConfig: config,
            shareToAuctionBps: 10_000,
            dopplerData: _getDopplerData(dopplerTickSpacing, asset < numeraire)
        });
        OpeningAuction auctionHook = _initializeAuction(initData, config, 100 ether);
        PoolKey memory poolKey = _buildPoolKey(auctionHook);
        _seedMisalignedNegativeClearingTick(auctionHook, poolKey, dopplerTickSpacing);
        int24 clearingTick = _settleAuction(auctionHook);
        assertLt(clearingTick, 0, "clearing tick should be negative");
        assertTrue(clearingTick % dopplerTickSpacing != 0, "clearing tick should be misaligned");
        int24 expectedAligned = alignTick(auctionHook.isToken0(), clearingTick, dopplerTickSpacing);
        _setDopplerSalt(auctionHook, initData.dopplerData, expectedAligned);
        uint256 governanceBefore = TestERC20(numeraire).balanceOf(governance);
        initializer.completeAuction(asset);
        uint256 governanceAfter = TestERC20(numeraire).balanceOf(governance);
        assertGt(governanceAfter - governanceBefore, 0, "numeraire proceeds not forwarded");
        _assertDopplerStartTick(poolKey, dopplerTickSpacing, expectedAligned);
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

    function _initializeAuction(
        OpeningAuctionInitData memory initData,
        OpeningAuctionConfig memory config,
        uint256 auctionTokens
    ) internal returns (OpeningAuction) {
        bytes32 auctionSalt = _mineOpeningAuctionSalt(config, auctionTokens);
        initializer.initialize(asset, numeraire, auctionTokens, auctionSalt, abi.encode(initData));
        return OpeningAuction(payable(initializer.getOpeningAuctionHook(asset)));
    }

    function _buildPoolKey(OpeningAuction auctionHook) internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            auctionHook.poolKey();
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function _settleAuction(OpeningAuction auctionHook) internal returns (int24) {
        vm.warp(auctionHook.auctionEndTime() + 1);
        auctionHook.settleAuction();
        assertEq(uint8(auctionHook.phase()), uint8(AuctionPhase.Settled));
        return auctionHook.clearingTick();
    }

    function _assertDopplerStartTick(
        PoolKey memory basePoolKey,
        int24 dopplerTickSpacing,
        int24 expectedAligned
    ) internal view {
        address dopplerHook = initializer.getDopplerHook(asset);
        PoolKey memory dopplerPoolKey = PoolKey({
            currency0: basePoolKey.currency0,
            currency1: basePoolKey.currency1,
            hooks: IHooks(dopplerHook),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: dopplerTickSpacing
        });

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(dopplerPoolKey.toId());
        int24 actualTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        assertEq(actualTick, expectedAligned, "doppler start tick should match aligned clearing tick");
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

    function _setDopplerSalt(
        OpeningAuction auctionHook,
        bytes memory dopplerData,
        int24 alignedClearingTick
    ) internal {
        bytes memory modifiedData = _modifyDopplerStartingTick(dopplerData, alignedClearingTick);
        DopplerData memory decoded = abi.decode(modifiedData, (DopplerData));

        uint256 unsoldTokens =
            auctionHook.totalAuctionTokens() - auctionHook.incentiveTokensTotal() - auctionHook.totalTokensSold();

        bytes memory constructorArgs = abi.encode(
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

        (, bytes32 salt) = HookMiner.find(
            address(dopplerDeployer),
            _dopplerHookFlags(),
            type(Doppler).creationCode,
            constructorArgs
        );

        dopplerDeployer.setNextSalt(salt);
        if (decoded.tickSpacing == 0) {
            revert("tickSpacing=0");
        }
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

    function _seedMisalignedNegativeClearingTick(
        OpeningAuction auctionHook,
        PoolKey memory poolKey,
        int24 dopplerTickSpacing
    ) internal {
        int24 tickLower = -60;
        uint128 liquidityStep = 1e22;

        for (uint256 i = 0; i < 20; i++) {
            _addBid(alice, poolKey, tickLower, liquidityStep);
            int24 quoted = _quoteClearingTick(auctionHook, poolKey);

            if (quoted < 0 && quoted > tickLower && quoted % dopplerTickSpacing != 0) {
                return;
            }
            if (quoted >= 0) {
                revert("clearing tick moved above zero");
            }
        }

        revert("could not find misaligned negative clearing tick");
    }

    function _addBid(address user, PoolKey memory poolKey, int24 tickLower, uint128 liquidity) internal {
        bytes32 salt = keccak256(abi.encode(user, bidNonce++));
        vm.prank(user);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + poolKey.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(user)
        );
    }

    function _quoteClearingTick(OpeningAuction auctionHook, PoolKey memory poolKey) internal view returns (int24) {
        uint256 tokensToSell = auctionHook.totalAuctionTokens() - auctionHook.incentiveTokensTotal();
        uint160 sqrtPriceLimitX96 = _sqrtPriceLimitX96(auctionHook.minAcceptableTick());

        (,, uint160 sqrtPriceAfterX96,) = QuoterMath.quote(
            manager,
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: auctionHook.isToken0(),
                amountSpecified: -int256(tokensToSell),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );

        return TickMath.getTickAtSqrtPrice(sqrtPriceAfterX96);
    }

    function _sqrtPriceLimitX96(int24 limitTick) internal pure returns (uint160) {
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        if (limit <= TickMath.MIN_SQRT_PRICE) {
            return TickMath.MIN_SQRT_PRICE + 1;
        }
        if (limit >= TickMath.MAX_SQRT_PRICE) {
            return TickMath.MAX_SQRT_PRICE - 1;
        }
        return limit;
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
}
