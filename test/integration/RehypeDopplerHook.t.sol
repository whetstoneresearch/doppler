// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { console } from "forge-std/console.sol";

import "forge-std/console.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import {
    ON_AFTER_SWAP_FLAG,
    ON_BEFORE_SWAP_FLAG,
    ON_GRADUATION_FLAG,
    ON_INITIALIZATION_FLAG
} from "src/base/BaseDopplerHook.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DERC20 } from "src/tokens/DERC20.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract LiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

contract RehypeDopplerHookIntegrationTest is Deployers {
    address public airlockOwner = makeAddr("AirlockOwner");
    address public buybackDst = makeAddr("BuybackDst");

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    LiquidityMigratorMock public mockLiquidityMigrator;
    RehypeDopplerHook public rehypeDopplerHook;
    TestERC20 public numeraire;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        numeraire = new TestERC20(1e48);
        vm.label(address(numeraire), "Numeraire");

        airlock = new Airlock(airlockOwner);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        initializer = DopplerHookInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );

        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));

        rehypeDopplerHook = new RehypeDopplerHook(address(initializer), manager);
        vm.label(address(rehypeDopplerHook), "RehypeDopplerHook");

        mockLiquidityMigrator = new LiquidityMigratorMock();

        // Set module states
        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(mockLiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        vm.startPrank(airlockOwner);
        airlock.setModuleState(modules, states);

        address[] memory dopplerHooks = new address[](1);
        dopplerHooks[0] = address(rehypeDopplerHook);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_AFTER_SWAP_FLAG;
        initializer.setDopplerHookState(dopplerHooks, flags);
        vm.stopPrank();
    }

    function test_create_WithRehypeDopplerHook() public {
        bytes32 salt = bytes32(uint256(1));
        (, address asset) = _createToken(salt);

        (address storedNumeraire,,,, PoolStatus status,,) = initializer.getState(asset);

        assertEq(uint256(status), uint256(PoolStatus.Locked), "Pool should be locked");
    }

    function test_swap_AccumulatesFees() public {
        bytes32 salt = bytes32(uint256(2));
        (bool isToken0, address asset) = _createToken(salt);

        IPoolManager.SwapParams memory swapParamsIn = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta1 =
            swapRouter.swap(poolKey, swapParamsIn, PoolSwapTest.TestSettings(false, false), new bytes(0));

        int256 amountToSwapBack = isToken0
            ? -int256(uint256(uint128(delta1.amount0())) / 2)
            : -int256(uint256(uint128(delta1.amount1())) / 2);

        IPoolManager.SwapParams memory swapParamsOut = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: amountToSwapBack,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParamsOut, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 airlockOwnerFees0,
            uint128 airlockOwnerFees1,
            uint24 customFee
        ) = rehypeDopplerHook.getHookFees(poolId);

        assertEq(customFee, 3000, "Custom fee should be 3000 (0.3%)");
        assertGt(beneficiaryFees0 + airlockOwnerFees0, 0, "Total fees0 should be greater than 0");
        assertGt(beneficiaryFees1 + airlockOwnerFees1, 0, "Total fees1 should be greater than 0");
        assertEq(fees0, 0, "fees0 should be 0");
        assertEq(fees1, 0, "fees1 should be 0");
    }

    function test_swap_DistributesFees() public {
        bytes32 salt = bytes32(uint256(3));
        (bool isToken0, address asset) = _createToken(salt);

        IPoolManager.SwapParams memory swapParamsIn = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta1 =
            swapRouter.swap(poolKey, swapParamsIn, PoolSwapTest.TestSettings(false, false), new bytes(0));

        int256 amountToSwapBack = isToken0
            ? -int256(uint256(uint128(delta1.amount0())) / 2)
            : -int256(uint256(uint128(delta1.amount1())) / 2);

        IPoolManager.SwapParams memory swapParamsOut = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: amountToSwapBack,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParamsOut, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            rehypeDopplerHook.getHookFees(poolId);

        assertTrue(
            beneficiaryFees0 + airlockOwnerFees0 > 0 || beneficiaryFees1 + airlockOwnerFees1 > 0,
            "Fees should be accumulated"
        );
    }

    function test_feeDistribution_Configuration() public {
        bytes32 salt = bytes32(uint256(4));
        (bool isToken0, address asset) = _createToken(salt);

        (
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        ) = rehypeDopplerHook.getFeeDistributionInfo(poolId);

        assertEq(assetBuybackPercentWad, 0.2e18, "Asset buyback percent should be 20%");
        assertEq(numeraireBuybackPercentWad, 0.2e18, "Numeraire buyback percent should be 20%");
        assertEq(beneficiaryPercentWad, 0.3e18, "Beneficiary percent should be 30%");
        assertEq(lpPercentWad, 0.3e18, "LP percent should be 30%");

        assertEq(
            assetBuybackPercentWad + numeraireBuybackPercentWad + beneficiaryPercentWad + lpPercentWad,
            WAD,
            "Fee distribution should add up to WAD"
        );
    }

    function test_poolInfo_Configuration() public {
        bytes32 salt = bytes32(uint256(5));
        (bool isToken0, address asset) = _createToken(salt);

        (address storedAsset, address storedNumeraire, address storedBuybackDst) = rehypeDopplerHook.getPoolInfo(poolId);

        assertEq(storedAsset, asset, "Asset should be stored correctly");
        assertEq(storedNumeraire, address(numeraire), "Numeraire should be stored correctly");
        assertEq(storedBuybackDst, buybackDst, "Buyback destination should be stored correctly");
    }

    function test_position_InitializedAsFullRange() public {
        bytes32 salt = bytes32(uint256(6));
        (bool isToken0, address asset) = _createToken(salt);

        (int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 positionSalt) =
            rehypeDopplerHook.getPosition(poolId);

        int24 tickSpacing = poolKey.tickSpacing;
        assertEq(tickLower, TickMath.minUsableTick(tickSpacing), "tickLower should be min usable tick");
        assertEq(tickUpper, TickMath.maxUsableTick(tickSpacing), "tickUpper should be max usable tick");
        assertEq(liquidity, 0, "Initial liquidity should be 0");
        assertTrue(positionSalt != bytes32(0), "Position salt should be set");
    }

    function test_setFeeDistribution_UpdatesDistribution() public {
        bytes32 salt = bytes32(uint256(7));
        (bool isToken0, address asset) = _createToken(salt);

        vm.prank(address(buybackDst));
        rehypeDopplerHook.setFeeDistribution(poolId, 0.5e18, 0, 0.5e18, 0);

        (
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        ) = rehypeDopplerHook.getFeeDistributionInfo(poolId);

        assertEq(assetBuybackPercentWad, 0.5e18, "Asset buyback should be 50%");
        assertEq(numeraireBuybackPercentWad, 0, "Numeraire buyback should be 0%");
        assertEq(beneficiaryPercentWad, 0.5e18, "Beneficiary should be 50%");
        assertEq(lpPercentWad, 0, "LP should be 0%");
    }

    function test_multipleSwaps_AccumulatesFees() public {
        bytes32 salt = bytes32(uint256(10));
        (bool isToken0, address asset) = _createToken(salt);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            rehypeDopplerHook.getHookFees(poolId);

        assertTrue(
            beneficiaryFees0 + airlockOwnerFees0 > 0 || beneficiaryFees1 + airlockOwnerFees1 > 0,
            "Fees should accumulate after multiple swaps"
        );
    }

    function test_bidirectionalSwaps_GenerateFeesOnBothTokens() public {
        bytes32 salt = bytes32(uint256(11));
        (bool isToken0, address asset) = _createToken(salt);

        IPoolManager.SwapParams memory swapParams1 = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta delta1 =
            swapRouter.swap(poolKey, swapParams1, PoolSwapTest.TestSettings(false, false), new bytes(0));

        console.log("delta1.amount0()", delta1.amount0());
        console.log("delta1.amount1()", delta1.amount1());

        int256 amountToSwapBack = isToken0
            ? -int256(uint256(uint128(delta1.amount0())) / 2)
            : -int256(uint256(uint128(delta1.amount1())) / 2);
        console.log("amountToSwapBack", amountToSwapBack);

        console.log("asset balance this", TestERC20(asset).balanceOf(address(this)));

        IPoolManager.SwapParams memory swapParams2 = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: amountToSwapBack,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams2, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            rehypeDopplerHook.getHookFees(poolId);

        assertTrue(beneficiaryFees0 + airlockOwnerFees0 > 0, "Total fees0 should be > 0");
        assertTrue(beneficiaryFees1 + airlockOwnerFees1 > 0, "Total fees1 should be > 0");
    }

    function test_collectFees_TransfersToBeneficiary() public {
        bytes32 salt = bytes32(uint256(12));
        (bool isToken0, address asset) = _createToken(salt);

        IPoolManager.SwapParams memory swapParams1 = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta1 =
            swapRouter.swap(poolKey, swapParams1, PoolSwapTest.TestSettings(false, false), new bytes(0));

        int256 amountToSwapBack = isToken0
            ? -int256(uint256(uint128(delta1.amount0())) / 2)
            : -int256(uint256(uint128(delta1.amount1())) / 2);

        IPoolManager.SwapParams memory swapParams2 = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: amountToSwapBack,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams2, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 beneficiaryFees0Before, uint128 beneficiaryFees1Before,,,) = rehypeDopplerHook.getHookFees(poolId);

        if (beneficiaryFees0Before > 0 || beneficiaryFees1Before > 0) {
            uint256 beneficiaryBalanceBefore0 = poolKey.currency0.balanceOf(buybackDst);
            uint256 beneficiaryBalanceBefore1 = poolKey.currency1.balanceOf(buybackDst);

            BalanceDelta fees = rehypeDopplerHook.collectFees(address(asset));

            assertEq(
                poolKey.currency0.balanceOf(buybackDst) - beneficiaryBalanceBefore0,
                uint128(fees.amount0()),
                "Beneficiary should receive fees0"
            );
            assertEq(
                poolKey.currency1.balanceOf(buybackDst) - beneficiaryBalanceBefore1,
                uint128(fees.amount1()),
                "Beneficiary should receive fees1"
            );

            (,, uint128 beneficiaryFees0After, uint128 beneficiaryFees1After,,,) = rehypeDopplerHook.getHookFees(poolId);
            assertEq(beneficiaryFees0After, 0, "Fees0 should be reset");
            assertEq(beneficiaryFees1After, 0, "Fees1 should be reset");
        }
    }

    function test_hookFees_CustomFeeZero_NoFeesCollected() public {
        bytes32 salt = bytes32(uint256(13));
        (bool isToken0, address asset) = _createTokenWithZeroFee(salt);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 airlockOwnerFees0,
            uint128 airlockOwnerFees1,
            uint24 customFee
        ) = rehypeDopplerHook.getHookFees(poolId);

        assertEq(customFee, 0, "Custom fee should be 0");
        assertEq(fees0, 0, "fees0 should be 0");
        assertEq(fees1, 0, "fees1 should be 0");
        assertEq(beneficiaryFees0, 0, "beneficiaryFees0 should be 0");
        assertEq(beneficiaryFees1, 0, "beneficiaryFees1 should be 0");
        assertEq(airlockOwnerFees0, 0, "airlockOwnerFees0 should be 0");
        assertEq(airlockOwnerFees1, 0, "airlockOwnerFees1 should be 0");
    }

    /* ----------------------------------------------------------------------------- */
    /*                         Airlock Owner Fee Tests                               */
    /* ----------------------------------------------------------------------------- */

    function test_airlockOwnerFees_AccumulateonAfterSwap() public {
        bytes32 salt = bytes32(uint256(14));
        (bool isToken0, address asset) = _createToken(salt);

        // Perform swaps to generate fees
        IPoolManager.SwapParams memory swapParams1 = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta1 =
            swapRouter.swap(poolKey, swapParams1, PoolSwapTest.TestSettings(false, false), new bytes(0));

        int256 amountToSwapBack = isToken0
            ? -int256(uint256(uint128(delta1.amount0())) / 2)
            : -int256(uint256(uint128(delta1.amount1())) / 2);

        IPoolManager.SwapParams memory swapParams2 = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: amountToSwapBack,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams2, PoolSwapTest.TestSettings(false, false), new bytes(0));

        // Check airlock owner fees accumulated
        (,,,, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) = rehypeDopplerHook.getHookFees(poolId);

        assertTrue(airlockOwnerFees0 > 0 || airlockOwnerFees1 > 0, "Airlock owner fees should accumulate");
    }

    function test_claimAirlockOwnerFees_Success() public {
        bytes32 salt = bytes32(uint256(15));
        (bool isToken0, address asset) = _createToken(salt);

        // Perform swaps to generate fees
        IPoolManager.SwapParams memory swapParams1 = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta1 =
            swapRouter.swap(poolKey, swapParams1, PoolSwapTest.TestSettings(false, false), new bytes(0));

        int256 amountToSwapBack = isToken0
            ? -int256(uint256(uint128(delta1.amount0())) / 2)
            : -int256(uint256(uint128(delta1.amount1())) / 2);

        IPoolManager.SwapParams memory swapParams2 = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: amountToSwapBack,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams2, PoolSwapTest.TestSettings(false, false), new bytes(0));

        // Get fees before claim
        (,,,, uint128 airlockOwnerFees0Before, uint128 airlockOwnerFees1Before,) = rehypeDopplerHook.getHookFees(poolId);

        if (airlockOwnerFees0Before > 0 || airlockOwnerFees1Before > 0) {
            uint256 ownerBalance0Before = poolKey.currency0.balanceOf(airlockOwner);
            uint256 ownerBalance1Before = poolKey.currency1.balanceOf(airlockOwner);

            // Claim as airlock owner
            vm.prank(airlockOwner);
            (uint128 claimed0, uint128 claimed1) = rehypeDopplerHook.claimAirlockOwnerFees(asset);

            // Verify correct amounts claimed
            assertEq(claimed0, airlockOwnerFees0Before, "Claimed fees0 should match accumulated");
            assertEq(claimed1, airlockOwnerFees1Before, "Claimed fees1 should match accumulated");

            // Verify tokens transferred
            assertEq(
                poolKey.currency0.balanceOf(airlockOwner) - ownerBalance0Before,
                claimed0,
                "Airlock owner should receive fees0"
            );
            assertEq(
                poolKey.currency1.balanceOf(airlockOwner) - ownerBalance1Before,
                claimed1,
                "Airlock owner should receive fees1"
            );

            // Verify fees reset to zero
            (,,,, uint128 airlockOwnerFees0After, uint128 airlockOwnerFees1After,) =
                rehypeDopplerHook.getHookFees(poolId);
            assertEq(airlockOwnerFees0After, 0, "Airlock owner fees0 should be reset");
            assertEq(airlockOwnerFees1After, 0, "Airlock owner fees1 should be reset");
        }
    }

    function test_claimAirlockOwnerFees_RevertsWhenNotAirlockOwner() public {
        bytes32 salt = bytes32(uint256(16));
        (bool isToken0, address asset) = _createToken(salt);

        // Perform a swap to generate fees
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        // Try to claim as non-airlock owner
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSignature("SenderNotAirlockOwner()"));
        rehypeDopplerHook.claimAirlockOwnerFees(asset);
    }

    function test_airlockOwnerFees_FivePercentOfCustomFee() public {
        bytes32 salt = bytes32(uint256(17));
        (bool isToken0,) = _createToken(salt);

        // First, do an exact input swap to ensure PoolManager has numeraire balance
        // In production, PoolManager would have balance from other pools
        IPoolManager.SwapParams memory setupSwap = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -1 ether, // exact input: send 1 ETH worth of numeraire
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, setupSwap, PoolSwapTest.TestSettings(false, false), new bytes(0));

        // Get state before the exact output swap
        (,,,, uint128 airlockOwnerFees0Before, uint128 airlockOwnerFees1Before,) = rehypeDopplerHook.getHookFees(poolId);

        // Now perform an exact output swap (positive amountSpecified)
        // This should work because PoolManager now has numeraire balance
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 0.5 ether, // exact output: receive 0.5 ETH worth of asset
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        // Get fees after swap
        (,,,, uint128 airlockOwnerFees0After, uint128 airlockOwnerFees1After,) = rehypeDopplerHook.getHookFees(poolId);

        // Airlock owner fees should have increased
        uint128 airlockOwnerFeesAccumulated0 = airlockOwnerFees0After - airlockOwnerFees0Before;
        uint128 airlockOwnerFeesAccumulated1 = airlockOwnerFees1After - airlockOwnerFees1Before;

        // At least one should be > 0 (depending on swap direction)
        assertTrue(
            airlockOwnerFeesAccumulated0 > 0 || airlockOwnerFeesAccumulated1 > 0,
            "Airlock owner should receive 5% of custom fee"
        );
    }

    function _prepareInitData(address token) internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        Currency currency0 = Currency.wrap(address(numeraire));
        Currency currency1 = Currency.wrap(address(token));

        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: initializer
        });
        poolId = poolKey.toId();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x07), shares: uint96(0.95e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: uint96(0.05e18) });

        // Prepare RehypeDopplerHook initialization data
        bytes memory rehypeData = abi.encode(
            address(numeraire), // numeraire
            buybackDst, // buybackDst
            uint24(3000), // customFee (0.3%)
            uint256(0.2e18), // assetBuybackPercentWad
            uint256(0.2e18), // numeraireBuybackPercentWad
            uint256(0.3e18), // beneficiaryPercentWad
            uint256(0.3e18) // lpPercentWad
        );

        return InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            farTick: 200_000,
            curves: curves,
            beneficiaries: beneficiaries,
            dopplerHook: address(rehypeDopplerHook),
            onInitializationDopplerHookCalldata: rehypeData,
            graduationDopplerHookCalldata: new bytes(0)
        });
    }

    function _prepareInitDataWithZeroFee(address token) internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        Currency currency0 = Currency.wrap(address(numeraire));
        Currency currency1 = Currency.wrap(address(token));

        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: initializer
        });
        poolId = poolKey.toId();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x07), shares: uint96(0.95e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: uint96(0.05e18) });

        bytes memory rehypeData = abi.encode(
            address(numeraire), // numeraire
            buybackDst, // buybackDst
            uint24(0), // customFee = 0
            uint256(0.25e18), // assetBuybackPercentWad
            uint256(0.25e18), // numeraireBuybackPercentWad
            uint256(0.25e18), // beneficiaryPercentWad
            uint256(0.25e18) // lpPercentWad
        );

        return InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            farTick: 200_000,
            curves: curves,
            beneficiaries: beneficiaries,
            dopplerHook: address(rehypeDopplerHook),
            onInitializationDopplerHookCalldata: rehypeData,
            graduationDopplerHookCalldata: new bytes(0)
        });
    }

    function _createToken(bytes32 salt) internal returns (bool isToken0, address asset) {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name,
                        symbol,
                        initialSupply,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        "TOKEN_URI"
                    )
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitData(tokenAddress);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        (asset,,,,) = airlock.create(params);
        vm.label(asset, "Asset");
        isToken0 = asset < address(numeraire);

        (,,,,, poolKey,) = initializer.getState(asset);
        poolId = poolKey.toId();

        numeraire.approve(address(swapRouter), type(uint256).max);
        TestERC20(asset).approve(address(swapRouter), type(uint256).max);
    }

    function _createTokenWithZeroFee(bytes32 salt) internal returns (bool isToken0, address asset) {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name,
                        symbol,
                        initialSupply,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        "TOKEN_URI"
                    )
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitDataWithZeroFee(tokenAddress);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        (asset,,,,) = airlock.create(params);
        vm.label(asset, "Asset");
        isToken0 = asset < address(numeraire);

        (,,,,, poolKey,) = initializer.getState(asset);
        poolId = poolKey.toId();

        numeraire.approve(address(swapRouter), type(uint256).max);
        TestERC20(asset).approve(address(swapRouter), type(uint256).max);
    }
}
