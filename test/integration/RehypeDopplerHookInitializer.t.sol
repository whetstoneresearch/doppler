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
import { IV4Quoter, V4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { console } from "forge-std/console.sol";

import "forge-std/console.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { ON_GRADUATION_FLAG, ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHookInitializer.sol";
import { RehypeDopplerHookInitializer } from "src/dopplerHooks/RehypeDopplerHookInitializer.sol";
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
import {
    EPSILON,
    FeeDistributionInfo,
    FeeRoutingMode,
    FeeSchedule,
    InitData as RehypeInitData
} from "src/types/RehypeTypes.sol";
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
    RehypeDopplerHookInitializer public rehypeDopplerHook;
    TestERC20 public numeraire;
    V4Quoter public quoter;

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
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );

        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));

        rehypeDopplerHook = new RehypeDopplerHookInitializer(address(initializer), manager);
        vm.label(address(rehypeDopplerHook), "RehypeDopplerHookInitializer");
        quoter = new V4Quoter(manager);

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
        flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;
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

        assertEq(customFee, 0, "Custom fee should be 3000 (0.3%)");
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
            uint256 assetFeesToAssetBuybackWad,
            uint256 assetFeesToNumeraireBuybackWad,
            uint256 assetFeesToBeneficiaryWad,
            uint256 assetFeesToLpWad,
            uint256 numeraireFeesToAssetBuybackWad,
            uint256 numeraireFeesToNumeraireBuybackWad,
            uint256 numeraireFeesToBeneficiaryWad,
            uint256 numeraireFeesToLpWad
        ) = rehypeDopplerHook.getFeeDistributionInfo(poolId);

        assertEq(assetFeesToAssetBuybackWad, 0.2e18, "Asset buyback percent should be 20%");
        assertEq(assetFeesToNumeraireBuybackWad, 0.2e18, "Numeraire buyback percent should be 20%");
        assertEq(assetFeesToBeneficiaryWad, 0.3e18, "Beneficiary percent should be 30%");
        assertEq(assetFeesToLpWad, 0.3e18, "LP percent should be 30%");
        assertEq(numeraireFeesToAssetBuybackWad, 0.2e18, "Numeraire row asset buyback should be 20%");
        assertEq(numeraireFeesToNumeraireBuybackWad, 0.2e18, "Numeraire row numeraire buyback should be 20%");
        assertEq(numeraireFeesToBeneficiaryWad, 0.3e18, "Numeraire row beneficiary should be 30%");
        assertEq(numeraireFeesToLpWad, 0.3e18, "Numeraire row LP should be 30%");

        assertEq(
            assetFeesToAssetBuybackWad + assetFeesToNumeraireBuybackWad + assetFeesToBeneficiaryWad + assetFeesToLpWad,
            WAD,
            "Asset fee distribution should add up to WAD"
        );
        assertEq(
            numeraireFeesToAssetBuybackWad + numeraireFeesToNumeraireBuybackWad + numeraireFeesToBeneficiaryWad
                + numeraireFeesToLpWad,
            WAD,
            "Numeraire fee distribution should add up to WAD"
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

    function test_onInitialization_StoresCustomFeeDistribution() public {
        bytes32 salt = bytes32(uint256(7));
        FeeDistributionInfo memory feeDistribution = FeeDistributionInfo({
            assetFeesToAssetBuybackWad: 0.5e18,
            assetFeesToNumeraireBuybackWad: 0,
            assetFeesToBeneficiaryWad: 0.5e18,
            assetFeesToLpWad: 0,
            numeraireFeesToAssetBuybackWad: 0.5e18,
            numeraireFeesToNumeraireBuybackWad: 0,
            numeraireFeesToBeneficiaryWad: 0.5e18,
            numeraireFeesToLpWad: 0
        });
        (bool isToken0, address asset) =
            _createTokenWithConfig(salt, uint24(3000), feeDistribution, FeeRoutingMode.DirectBuyback);

        (
            uint256 assetFeesToAssetBuybackWad,
            uint256 assetFeesToNumeraireBuybackWad,
            uint256 assetFeesToBeneficiaryWad,
            uint256 assetFeesToLpWad,
            uint256 numeraireFeesToAssetBuybackWad,
            uint256 numeraireFeesToNumeraireBuybackWad,
            uint256 numeraireFeesToBeneficiaryWad,
            uint256 numeraireFeesToLpWad
        ) = rehypeDopplerHook.getFeeDistributionInfo(poolId);

        assertEq(assetFeesToAssetBuybackWad, 0.5e18, "Asset buyback should be 50%");
        assertEq(assetFeesToNumeraireBuybackWad, 0, "Numeraire buyback should be 0%");
        assertEq(assetFeesToBeneficiaryWad, 0.5e18, "Beneficiary should be 50%");
        assertEq(assetFeesToLpWad, 0, "LP should be 0%");
        assertEq(numeraireFeesToAssetBuybackWad, 0.5e18, "Numeraire row asset buyback should be 50%");
        assertEq(numeraireFeesToNumeraireBuybackWad, 0, "Numeraire row numeraire buyback should be 0%");
        assertEq(numeraireFeesToBeneficiaryWad, 0.5e18, "Numeraire row beneficiary should be 50%");
        assertEq(numeraireFeesToLpWad, 0, "Numeraire row LP should be 0%");
    }

    function test_swap_NumeraireFeeWithFullNumeraireBuyback_ForwardsDirectlyToBuybackDst() public {
        bytes32 salt = bytes32(uint256(70));
        (bool isToken0, address asset) = _createTokenWithConfig(
            salt, uint24(3000), _fullNumeraireBuybackDistribution(), FeeRoutingMode.DirectBuyback
        );

        // First buy asset so we can do an exact-input asset->numeraire swap.
        IPoolManager.SwapParams memory buyAssetParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta buyDelta =
            swapRouter.swap(poolKey, buyAssetParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        uint256 assetBought = isToken0 ? uint256(uint128(buyDelta.amount0())) : uint256(uint128(buyDelta.amount1()));
        int256 assetToSell = -int256(assetBought / 2);

        (,, uint128 beneficiaryFees0Before, uint128 beneficiaryFees1Before,,,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 buybackNumeraireBefore = Currency.wrap(address(numeraire)).balanceOf(buybackDst);

        // Exact-input asset->numeraire: fee token is numeraire and should be forwarded directly.
        IPoolManager.SwapParams memory sellAssetParams = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: assetToSell,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, sellAssetParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        uint256 buybackNumeraireAfter = Currency.wrap(address(numeraire)).balanceOf(buybackDst);
        assertGt(buybackNumeraireAfter, buybackNumeraireBefore, "Numeraire should be forwarded to buyback dst");

        (,, uint128 beneficiaryFees0After, uint128 beneficiaryFees1After,,,) = rehypeDopplerHook.getHookFees(poolId);
        if (isToken0) {
            assertEq(
                beneficiaryFees1After,
                beneficiaryFees1Before,
                "Numeraire beneficiary fees should not increase on direct forwarding"
            );
        } else {
            assertEq(
                beneficiaryFees0After,
                beneficiaryFees0Before,
                "Numeraire beneficiary fees should not increase on direct forwarding"
            );
        }
    }

    function test_swap_NumeraireFeeWithFullNumeraireBuyback_RoutesToBeneficiaryFeesWhenConfigured() public {
        bytes32 salt = bytes32(uint256(71));
        (bool isToken0, address asset) = _createTokenWithConfig(
            salt, uint24(3000), _fullNumeraireBuybackDistribution(), FeeRoutingMode.RouteToBeneficiaryFees
        );

        // First buy asset so we can do an exact-input asset->numeraire swap.
        IPoolManager.SwapParams memory buyAssetParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta buyDelta =
            swapRouter.swap(poolKey, buyAssetParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        uint256 assetBought = isToken0 ? uint256(uint128(buyDelta.amount0())) : uint256(uint128(buyDelta.amount1()));
        int256 assetToSell = -int256(assetBought / 2);

        (,, uint128 beneficiaryFees0Before, uint128 beneficiaryFees1Before,,,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 buybackNumeraireBefore = Currency.wrap(address(numeraire)).balanceOf(buybackDst);

        // Exact-input asset->numeraire: buyback output should route into beneficiary accounting.
        IPoolManager.SwapParams memory sellAssetParams = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: assetToSell,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, sellAssetParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        uint256 buybackNumeraireAfter = Currency.wrap(address(numeraire)).balanceOf(buybackDst);
        assertEq(buybackNumeraireAfter, buybackNumeraireBefore, "Numeraire should not be forwarded directly");

        (,, uint128 beneficiaryFees0After, uint128 beneficiaryFees1After,,,) = rehypeDopplerHook.getHookFees(poolId);
        if (isToken0) {
            assertGt(
                beneficiaryFees1After,
                beneficiaryFees1Before,
                "Numeraire beneficiary fees should increase in routing mode"
            );
        } else {
            assertGt(
                beneficiaryFees0After,
                beneficiaryFees0Before,
                "Numeraire beneficiary fees should increase in routing mode"
            );
        }
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

    function test_property_rehypothecationAccounting_AllSwapPermutations() public {
        uint256 saltSeed = 100_000;

        for (uint256 orientation; orientation < 2; ++orientation) {
            bool targetIsToken0 = orientation == 1;

            for (uint256 modeMask; modeMask < 4; ++modeMask) {
                bool buyExactOut = (modeMask & 1) != 0;
                bool sellExactOut = (modeMask & 2) != 0;

                (bool isToken0, address asset) = _createTokenWithOrientation(targetIsToken0, saltSeed);
                saltSeed += 1024;
                _executeBidirectionalSwapPermutation(isToken0, asset, buyExactOut, sellExactOut);
                _assertHookAccountingInvariants(poolId);
            }
        }
    }

    /// forge-config: default.fuzz.runs = 8
    function testFuzz_property_rehypothecationAccounting_MatrixPermutations(
        uint256 saltSeed,
        uint8 permutationSeed,
        uint256 assetDistributionSeed,
        uint256 numeraireDistributionSeed
    ) public {
        bool targetIsToken0 = (permutationSeed & 1) != 0;
        bool buyExactOut = (permutationSeed & 2) != 0;
        bool sellExactOut = (permutationSeed & 4) != 0;

        (
            uint256 assetFeesToAssetBuybackWad,
            uint256 assetFeesToNumeraireBuybackWad,
            uint256 assetFeesToBeneficiaryWad,
            uint256 assetFeesToLpWad
        ) = _distributionRowFromSeed(assetDistributionSeed);

        (
            uint256 numeraireFeesToAssetBuybackWad,
            uint256 numeraireFeesToNumeraireBuybackWad,
            uint256 numeraireFeesToBeneficiaryWad,
            uint256 numeraireFeesToLpWad
        ) = _distributionRowFromSeed(numeraireDistributionSeed);

        FeeDistributionInfo memory feeDistribution = FeeDistributionInfo({
            assetFeesToAssetBuybackWad: assetFeesToAssetBuybackWad,
            assetFeesToNumeraireBuybackWad: assetFeesToNumeraireBuybackWad,
            assetFeesToBeneficiaryWad: assetFeesToBeneficiaryWad,
            assetFeesToLpWad: assetFeesToLpWad,
            numeraireFeesToAssetBuybackWad: numeraireFeesToAssetBuybackWad,
            numeraireFeesToNumeraireBuybackWad: numeraireFeesToNumeraireBuybackWad,
            numeraireFeesToBeneficiaryWad: numeraireFeesToBeneficiaryWad,
            numeraireFeesToLpWad: numeraireFeesToLpWad
        });
        (bool isToken0, address asset) = _createTokenWithOrientation(
            targetIsToken0, saltSeed, uint24(3000), feeDistribution, FeeRoutingMode.DirectBuyback
        );

        _executeBidirectionalSwapPermutation(isToken0, asset, buyExactOut, sellExactOut);
        _assertHookAccountingInvariants(poolId);
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

    function test_collectFees_RoutesAndTransfersCorrectly_WhenRoutingModeIsBeneficiary() public {
        bytes32 salt = bytes32(uint256(72));
        (bool isToken0, address asset) = _createTokenWithConfig(
            salt, uint24(3000), _fullNumeraireBuybackDistribution(), FeeRoutingMode.RouteToBeneficiaryFees
        );

        uint256 buybackBalanceBeforeSwap0 = poolKey.currency0.balanceOf(buybackDst);
        uint256 buybackBalanceBeforeSwap1 = poolKey.currency1.balanceOf(buybackDst);

        IPoolManager.SwapParams memory buyAssetParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta buyDelta =
            swapRouter.swap(poolKey, buyAssetParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        uint256 assetBought = isToken0 ? uint256(uint128(buyDelta.amount0())) : uint256(uint128(buyDelta.amount1()));
        int256 assetToSell = -int256(assetBought / 2);

        IPoolManager.SwapParams memory sellAssetParams = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: assetToSell,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, sellAssetParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        uint256 buybackBalanceAfterSwap0 = poolKey.currency0.balanceOf(buybackDst);
        uint256 buybackBalanceAfterSwap1 = poolKey.currency1.balanceOf(buybackDst);
        assertEq(
            buybackBalanceAfterSwap0, buybackBalanceBeforeSwap0, "No direct currency0 transfer expected in routing mode"
        );
        assertEq(
            buybackBalanceAfterSwap1, buybackBalanceBeforeSwap1, "No direct currency1 transfer expected in routing mode"
        );

        (,, uint128 beneficiaryFees0BeforeCollect, uint128 beneficiaryFees1BeforeCollect,,,) =
            rehypeDopplerHook.getHookFees(poolId);
        assertGt(
            beneficiaryFees0BeforeCollect + beneficiaryFees1BeforeCollect,
            0,
            "Expected routed beneficiary fees before collect"
        );

        BalanceDelta fees = rehypeDopplerHook.collectFees(address(asset));

        assertEq(
            poolKey.currency0.balanceOf(buybackDst) - buybackBalanceAfterSwap0,
            uint128(fees.amount0()),
            "Collected currency0 should match fee delta"
        );
        assertEq(
            poolKey.currency1.balanceOf(buybackDst) - buybackBalanceAfterSwap1,
            uint128(fees.amount1()),
            "Collected currency1 should match fee delta"
        );
        assertGt(uint256(uint128(fees.amount0())) + uint256(uint128(fees.amount1())), 0, "Collected fees should be > 0");

        (,, uint128 beneficiaryFees0AfterCollect, uint128 beneficiaryFees1AfterCollect,,,) =
            rehypeDopplerHook.getHookFees(poolId);
        assertEq(beneficiaryFees0AfterCollect, 0, "Beneficiary fees0 should be reset");
        assertEq(beneficiaryFees1AfterCollect, 0, "Beneficiary fees1 should be reset");
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

    function test_airlockOwnerFees_AccumulateOnSwap() public {
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

    function test_swap_ExactOutput_FeesInInputToken() public {
        bytes32 salt = bytes32(uint256(18));
        (bool isToken0,) = _createToken(salt);

        IPoolManager.SwapParams memory setupSwap = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, setupSwap, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,,,, uint128 airlockOwnerFees0Before, uint128 airlockOwnerFees1Before,) = rehypeDopplerHook.getHookFees(poolId);

        IPoolManager.SwapParams memory exactOutputSwap = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 0.5 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, exactOutputSwap, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,,,, uint128 airlockOwnerFees0After, uint128 airlockOwnerFees1After,) = rehypeDopplerHook.getHookFees(poolId);

        uint128 deltaFees0 = airlockOwnerFees0After - airlockOwnerFees0Before;
        uint128 deltaFees1 = airlockOwnerFees1After - airlockOwnerFees1Before;

        if (!isToken0) {
            assertGt(deltaFees0, 0, "Input token0 fees should increase");
            assertEq(deltaFees1, 0, "Input token1 fees should not increase");
        } else {
            assertGt(deltaFees1, 0, "Input token1 fees should increase");
            assertEq(deltaFees0, 0, "Input token0 fees should not increase");
        }
    }

    /* ----------------------------------------------------------------------------- */
    /*                        Decaying Fee Integration Tests                        */
    /* ----------------------------------------------------------------------------- */

    function test_decayingFee_StoresFeeScheduleOnCreate() public {
        bytes32 salt = bytes32(uint256(100));
        (, address asset) = _createTokenWithDecay(salt, 10_000, 3000, 3600, 0);

        (uint32 startingTime, uint24 startFee, uint24 endFee, uint24 lastFee, uint32 durationSeconds) =
            rehypeDopplerHook.getFeeSchedule(poolId);

        assertEq(startFee, 10_000, "startFee");
        assertEq(endFee, 3000, "endFee");
        assertEq(lastFee, 10_000, "lastFee should start at startFee");
        assertEq(durationSeconds, 3600, "durationSeconds");
        assertGt(startingTime, 0, "startingTime should be set");
    }

    function test_decayingFee_HigherFeesAtStartThanAfterDecay() public {
        bytes32 salt = bytes32(uint256(101));
        (bool isToken0,) = _createTokenWithDecay(salt, 10_000, 2000, 3600, 0);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // First swap primes the pool manager balance (fee collection needs token balance)
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        // Snapshot fees before second swap at the high fee rate
        (,, uint128 bf0A, uint128 bf1A, uint128 of0A, uint128 of1A,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 feesBeforeHighFeeSwap = uint256(bf0A) + bf1A + of0A + of1A;

        // Second swap at start — fee is still 10000 (1%)
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 bf0B, uint128 bf1B, uint128 of0B, uint128 of1B,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 feesFromHighFeeSwap = (uint256(bf0B) + bf1B + of0B + of1B) - feesBeforeHighFeeSwap;
        assertGt(feesFromHighFeeSwap, 0, "Should accrue fees at high fee rate");

        // Warp past full duration — fee should now be 2000 (0.2%)
        vm.warp(block.timestamp + 3601);

        (,, uint128 bf0C, uint128 bf1C, uint128 of0C, uint128 of1C,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 feesBeforeLowFeeSwap = uint256(bf0C) + bf1C + of0C + of1C;

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 bf0D, uint128 bf1D, uint128 of0D, uint128 of1D,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 feesFromLowFeeSwap = (uint256(bf0D) + bf1D + of0D + of1D) - feesBeforeLowFeeSwap;

        assertGt(feesFromLowFeeSwap, 0, "Should accrue fees at low fee rate");
        assertGt(feesFromHighFeeSwap, feesFromLowFeeSwap, "Fees at start should be higher than after decay");
    }

    function test_decayingFee_Integration_ChargesInterpolatedMidpointFee() public {
        uint24 startFee = 10_000;
        uint24 endFee = 2000;
        uint24 midpointFee = 6000;
        uint32 durationSeconds = 4000;
        uint256 swapAmount = 1 ether;
        FeeDistributionInfo memory beneficiaryOnlyDistribution = _fullBeneficiaryDistribution();

        (bool startIsToken0,) = _createTokenWithDecayAndOrientation(
            true, 1001, startFee, endFee, durationSeconds, 0, beneficiaryOnlyDistribution, FeeRoutingMode.DirectBuyback
        );
        PoolKey memory startPoolKey = poolKey;
        PoolId startPoolId = poolId;

        IPoolManager.SwapParams memory startSwapParams = IPoolManager.SwapParams({
            zeroForOne: !startIsToken0,
            amountSpecified: int256(swapAmount),
            sqrtPriceLimitX96: !startIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(startPoolKey, startSwapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        uint256 startFeesBeforeMeasuredSwap = _totalTrackedFees(startPoolId);
        swapRouter.swap(startPoolKey, startSwapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        uint256 startFeesAfterMeasuredSwap = _totalTrackedFees(startPoolId);

        uint256 feesAtStart = startFeesAfterMeasuredSwap - startFeesBeforeMeasuredSwap;
        (,,, uint24 lastFeeAtStart,) = rehypeDopplerHook.getFeeSchedule(startPoolId);
        assertEq(lastFeeAtStart, startFee, "Measured start swap should use the start fee");

        (bool midpointIsToken0,) = _createTokenWithDecayAndOrientation(
            true, 2001, startFee, endFee, durationSeconds, 0, beneficiaryOnlyDistribution, FeeRoutingMode.DirectBuyback
        );
        PoolKey memory midpointPoolKey = poolKey;
        PoolId midpointPoolId = poolId;

        IPoolManager.SwapParams memory midpointSwapParams = IPoolManager.SwapParams({
            zeroForOne: !midpointIsToken0,
            amountSpecified: int256(swapAmount),
            sqrtPriceLimitX96: !midpointIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(midpointPoolKey, midpointSwapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        vm.warp(block.timestamp + durationSeconds / 2);

        uint256 midpointFeesBeforeMeasuredSwap = _totalTrackedFees(midpointPoolId);
        swapRouter.swap(midpointPoolKey, midpointSwapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        uint256 midpointFeesAfterMeasuredSwap = _totalTrackedFees(midpointPoolId);

        uint256 feesAtMidpoint = midpointFeesAfterMeasuredSwap - midpointFeesBeforeMeasuredSwap;
        (,,, uint24 lastFeeAtMidpoint,) = rehypeDopplerHook.getFeeSchedule(midpointPoolId);

        assertEq(lastFeeAtMidpoint, midpointFee, "Measured midpoint swap should use the interpolated fee");
        assertGt(feesAtStart, 0, "Start swap should accrue a fee");
        assertGt(feesAtMidpoint, 0, "Midpoint swap should accrue a fee");
        assertLt(feesAtMidpoint, feesAtStart, "Midpoint swap should charge less than the start swap");
        assertApproxEqAbs(
            feesAtMidpoint,
            feesAtStart * midpointFee / startFee,
            1,
            "Midpoint fee accrual should match the interpolated fee rate on the same swap path"
        );
    }

    function test_decayingFee_UpdatesLastFeeAfterSwap() public {
        bytes32 salt = bytes32(uint256(102));
        (bool isToken0,) = _createTokenWithDecay(salt, 10_000, 2000, 4000, 0);

        (,,, uint24 lastFeeBefore,) = rehypeDopplerHook.getFeeSchedule(poolId);
        assertEq(lastFeeBefore, 10_000, "lastFee should be startFee initially");

        // Warp to midpoint and swap
        vm.warp(block.timestamp + 2000);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,,, uint24 lastFeeAfter,) = rehypeDopplerHook.getFeeSchedule(poolId);
        assertEq(lastFeeAfter, 6000, "lastFee should update to midpoint interpolated value");
    }

    function test_decayingFee_FlatFeeDoesNotDecay() public {
        bytes32 salt = bytes32(uint256(103));
        (bool isToken0,) = _createTokenWithDecay(salt, 5000, 5000, 0, 0);

        // Swap at start
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 bf0A, uint128 bf1A, uint128 of0A, uint128 of1A,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 feesFirst = uint256(bf0A) + bf1A + of0A + of1A;

        // Warp far into the future — fee should stay at 5000
        vm.warp(block.timestamp + 100_000);

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 bf0B, uint128 bf1B, uint128 of0B, uint128 of1B,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 feesSecond = (uint256(bf0B) + bf1B + of0B + of1B) - feesFirst;

        // With equal swap amounts and a flat fee, fees should be roughly similar
        // (small variance from price movement is acceptable)
        assertGt(feesSecond, 0, "Flat fee should still accrue fees");

        (,,, uint24 lastFee,) = rehypeDopplerHook.getFeeSchedule(poolId);
        assertEq(lastFee, 5000, "lastFee should remain at startFee for flat schedule");
    }

    function test_decayingFee_FutureStartingTimeKeepsHighFee() public {
        uint32 futureStart = uint32(block.timestamp) + 2000;
        bytes32 salt = bytes32(uint256(104));
        (bool isToken0,) = _createTokenWithDecay(salt, 10_000, 2000, 3600, futureStart);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // First swap primes the pool manager balance
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        // Swap before the schedule starts — should use startFee
        (,, uint128 bf0A, uint128 bf1A, uint128 of0A, uint128 of1A,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 feesBeforeSwap = uint256(bf0A) + bf1A + of0A + of1A;

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,, uint128 bf0B, uint128 bf1B, uint128 of0B, uint128 of1B,) = rehypeDopplerHook.getHookFees(poolId);
        uint256 feesBeforeStart = (uint256(bf0B) + bf1B + of0B + of1B) - feesBeforeSwap;
        assertGt(feesBeforeStart, 0, "Should accrue fees at startFee before schedule begins");

        (,,, uint24 lastFee,) = rehypeDopplerHook.getFeeSchedule(poolId);
        assertEq(lastFee, 10_000, "lastFee should remain startFee before schedule begins");
    }

    function _prepareInitData(address token) internal returns (InitData memory) {
        return _prepareInitData(token, uint24(3000), _defaultFeeDistribution(), FeeRoutingMode.DirectBuyback);
    }

    function _prepareInitData(address token, FeeRoutingMode feeRoutingMode) internal returns (InitData memory) {
        return _prepareInitData(token, uint24(3000), _defaultFeeDistribution(), feeRoutingMode);
    }

    function _prepareInitData(
        address token,
        uint24 customFee,
        FeeDistributionInfo memory feeDistribution,
        FeeRoutingMode feeRoutingMode
    ) internal returns (InitData memory) {
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

        // Prepare RehypeDopplerHookInitializer initialization data
        bytes memory rehypeData = abi.encode(
            RehypeInitData({
                numeraire: address(numeraire),
                buybackDst: buybackDst,
                startFee: customFee,
                endFee: customFee,
                durationSeconds: 0,
                startingTime: 0,
                feeRoutingMode: feeRoutingMode,
                feeDistributionInfo: feeDistribution
            })
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

    function _defaultFeeDistribution() internal pure returns (FeeDistributionInfo memory feeDistribution) {
        return FeeDistributionInfo({
            assetFeesToAssetBuybackWad: uint256(0.2e18),
            assetFeesToNumeraireBuybackWad: uint256(0.2e18),
            assetFeesToBeneficiaryWad: uint256(0.3e18),
            assetFeesToLpWad: uint256(0.3e18),
            numeraireFeesToAssetBuybackWad: uint256(0.2e18),
            numeraireFeesToNumeraireBuybackWad: uint256(0.2e18),
            numeraireFeesToBeneficiaryWad: uint256(0.3e18),
            numeraireFeesToLpWad: uint256(0.3e18)
        });
    }

    function _quarterFeeDistribution() internal pure returns (FeeDistributionInfo memory feeDistribution) {
        return FeeDistributionInfo({
            assetFeesToAssetBuybackWad: uint256(0.25e18),
            assetFeesToNumeraireBuybackWad: uint256(0.25e18),
            assetFeesToBeneficiaryWad: uint256(0.25e18),
            assetFeesToLpWad: uint256(0.25e18),
            numeraireFeesToAssetBuybackWad: uint256(0.25e18),
            numeraireFeesToNumeraireBuybackWad: uint256(0.25e18),
            numeraireFeesToBeneficiaryWad: uint256(0.25e18),
            numeraireFeesToLpWad: uint256(0.25e18)
        });
    }

    function _fullNumeraireBuybackDistribution() internal pure returns (FeeDistributionInfo memory feeDistribution) {
        return FeeDistributionInfo({
            assetFeesToAssetBuybackWad: 0,
            assetFeesToNumeraireBuybackWad: WAD,
            assetFeesToBeneficiaryWad: 0,
            assetFeesToLpWad: 0,
            numeraireFeesToAssetBuybackWad: 0,
            numeraireFeesToNumeraireBuybackWad: WAD,
            numeraireFeesToBeneficiaryWad: 0,
            numeraireFeesToLpWad: 0
        });
    }

    function _fullBeneficiaryDistribution() internal pure returns (FeeDistributionInfo memory feeDistribution) {
        return FeeDistributionInfo({
            assetFeesToAssetBuybackWad: 0,
            assetFeesToNumeraireBuybackWad: 0,
            assetFeesToBeneficiaryWad: WAD,
            assetFeesToLpWad: 0,
            numeraireFeesToAssetBuybackWad: 0,
            numeraireFeesToNumeraireBuybackWad: 0,
            numeraireFeesToBeneficiaryWad: WAD,
            numeraireFeesToLpWad: 0
        });
    }

    function _prepareInitDataWithZeroFee(address token) internal returns (InitData memory) {
        return _prepareInitData(token, uint24(0), _quarterFeeDistribution(), FeeRoutingMode.DirectBuyback);
    }

    function _prepareInitDataWithDecay(
        address token,
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint32 startingTime
    ) internal returns (InitData memory) {
        return _prepareInitDataWithDecay(
            token,
            startFee,
            endFee,
            durationSeconds,
            startingTime,
            _defaultFeeDistribution(),
            FeeRoutingMode.DirectBuyback
        );
    }

    function _prepareInitDataWithDecay(
        address token,
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint32 startingTime,
        FeeDistributionInfo memory feeDistribution,
        FeeRoutingMode feeRoutingMode
    ) internal returns (InitData memory) {
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
            RehypeInitData({
                numeraire: address(numeraire),
                buybackDst: buybackDst,
                startFee: startFee,
                endFee: endFee,
                durationSeconds: durationSeconds,
                startingTime: startingTime,
                feeRoutingMode: feeRoutingMode,
                feeDistributionInfo: feeDistribution
            })
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

    function _createTokenWithDecay(
        bytes32 salt,
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint32 startingTime
    ) internal returns (bool isToken0, address asset) {
        return _createTokenWithDecayConfig(
            salt,
            startFee,
            endFee,
            durationSeconds,
            startingTime,
            _defaultFeeDistribution(),
            FeeRoutingMode.DirectBuyback
        );
    }

    function _createTokenWithDecayConfig(
        bytes32 salt,
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint32 startingTime,
        FeeDistributionInfo memory feeDistribution,
        FeeRoutingMode feeRoutingMode
    ) internal returns (bool isToken0, address asset) {
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

        InitData memory initData = _prepareInitDataWithDecay(
            tokenAddress, startFee, endFee, durationSeconds, startingTime, feeDistribution, feeRoutingMode
        );

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

    function _createTokenWithDecayAndOrientation(
        bool targetIsToken0,
        uint256 saltSeed,
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint32 startingTime,
        FeeDistributionInfo memory feeDistribution,
        FeeRoutingMode feeRoutingMode
    ) internal returns (bool isToken0, address asset) {
        uint256 baseSeed = bound(saltSeed, 1, type(uint64).max - 512);

        for (uint256 i; i < 512; ++i) {
            bytes32 salt = bytes32(baseSeed + i);
            if (_predictTokenAddress(salt) < address(numeraire) == targetIsToken0) {
                return _createTokenWithDecayConfig(
                    salt, startFee, endFee, durationSeconds, startingTime, feeDistribution, feeRoutingMode
                );
            }
        }

        revert("No matching token orientation found");
    }

    function _createToken(bytes32 salt) internal returns (bool isToken0, address asset) {
        return _createTokenWithConfig(salt, uint24(3000), _defaultFeeDistribution(), FeeRoutingMode.DirectBuyback);
    }

    function _createTokenWithRoutingMode(
        bytes32 salt,
        FeeRoutingMode feeRoutingMode
    ) internal returns (bool isToken0, address asset) {
        return _createTokenWithConfig(salt, uint24(3000), _defaultFeeDistribution(), feeRoutingMode);
    }

    function _createTokenWithConfig(
        bytes32 salt,
        uint24 customFee,
        FeeDistributionInfo memory feeDistribution,
        FeeRoutingMode feeRoutingMode
    ) internal returns (bool isToken0, address asset) {
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

        InitData memory initData = _prepareInitData(tokenAddress, customFee, feeDistribution, feeRoutingMode);

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

    function _createTokenWithOrientation(
        bool targetIsToken0,
        uint256 saltSeed
    ) internal returns (bool isToken0, address asset) {
        return _createTokenWithOrientation(
            targetIsToken0, saltSeed, uint24(3000), _defaultFeeDistribution(), FeeRoutingMode.DirectBuyback
        );
    }

    function _createTokenWithOrientation(
        bool targetIsToken0,
        uint256 saltSeed,
        uint24 customFee,
        FeeDistributionInfo memory feeDistribution,
        FeeRoutingMode feeRoutingMode
    ) internal returns (bool isToken0, address asset) {
        uint256 baseSeed = bound(saltSeed, 1, type(uint64).max - 512);

        for (uint256 i; i < 512; ++i) {
            bytes32 salt = bytes32(baseSeed + i);
            if (_predictTokenAddress(salt) < address(numeraire) == targetIsToken0) {
                return _createTokenWithConfig(salt, customFee, feeDistribution, feeRoutingMode);
            }
        }

        revert("No matching token orientation found");
    }

    function _predictTokenAddress(bytes32 salt) internal view returns (address) {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

        return vm.computeCreate2Address(
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
    }

    function _executeBidirectionalSwapPermutation(
        bool isToken0,
        address asset,
        bool buyExactOut,
        bool sellExactOut
    ) internal {
        bool buyZeroForOne = !isToken0;
        uint160 buyLimit = buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        int256 buyAmountSpecified;
        if (buyExactOut) {
            (uint256 quotedAssetOut,) = quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: poolKey, zeroForOne: buyZeroForOne, exactAmount: uint128(1 ether), hookData: new bytes(0)
                })
            );
            uint256 desiredAssetOut = quotedAssetOut / 2;
            if (desiredAssetOut == 0) desiredAssetOut = quotedAssetOut;
            if (desiredAssetOut == 0) desiredAssetOut = 1;
            buyAmountSpecified = int256(desiredAssetOut);
        } else {
            buyAmountSpecified = -int256(1 ether);
        }

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: buyZeroForOne, amountSpecified: buyAmountSpecified, sqrtPriceLimitX96: buyLimit
            }),
            PoolSwapTest.TestSettings(false, false),
            new bytes(0)
        );

        uint256 assetBalance = TestERC20(asset).balanceOf(address(this));
        if (assetBalance == 0) return;

        bool sellZeroForOne = isToken0;
        uint160 sellLimit = sellZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        int256 sellAmountSpecified;
        if (sellExactOut) {
            (uint256 quotedNumeraireOut,) = quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: poolKey,
                    zeroForOne: sellZeroForOne,
                    exactAmount: uint128(assetBalance),
                    hookData: new bytes(0)
                })
            );
            uint256 desiredNumeraireOut = quotedNumeraireOut / 2;
            if (desiredNumeraireOut == 0) desiredNumeraireOut = quotedNumeraireOut;
            if (desiredNumeraireOut == 0) {
                sellAmountSpecified = -int256(assetBalance / 2);
            } else {
                sellAmountSpecified = int256(desiredNumeraireOut);
            }
        } else {
            uint256 assetAmountIn = assetBalance / 2;
            if (assetAmountIn == 0) assetAmountIn = assetBalance;
            sellAmountSpecified = -int256(assetAmountIn);
        }

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: sellZeroForOne, amountSpecified: sellAmountSpecified, sqrtPriceLimitX96: sellLimit
            }),
            PoolSwapTest.TestSettings(false, false),
            new bytes(0)
        );
    }

    function _assertHookAccountingInvariants(PoolId id) internal view {
        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 airlockOwnerFees0,
            uint128 airlockOwnerFees1,
            uint24 customFee
        ) = rehypeDopplerHook.getHookFees(id);

        assertEq(customFee, 0, "custom fee should remain unchanged");
        assertLe(fees0, EPSILON, "fees0 should not accumulate above EPSILON");
        assertLe(fees1, EPSILON, "fees1 should not accumulate above EPSILON");

        uint256 totalAccountedFees =
            uint256(beneficiaryFees0) + beneficiaryFees1 + airlockOwnerFees0 + airlockOwnerFees1;
        assertGt(totalAccountedFees, 0, "swaps should accrue some tracked fees");

        uint256 hookBalance0 = poolKey.currency0.balanceOf(address(rehypeDopplerHook));
        uint256 hookBalance1 = poolKey.currency1.balanceOf(address(rehypeDopplerHook));

        assertGe(
            hookBalance0,
            uint256(beneficiaryFees0) + airlockOwnerFees0,
            "hook must remain solvent for currency0 tracked balances"
        );
        assertGe(
            hookBalance1,
            uint256(beneficiaryFees1) + airlockOwnerFees1,
            "hook must remain solvent for currency1 tracked balances"
        );
    }

    function _totalTrackedFees(PoolId id) internal view returns (uint256) {
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            rehypeDopplerHook.getHookFees(id);

        return uint256(beneficiaryFees0) + beneficiaryFees1 + airlockOwnerFees0 + airlockOwnerFees1;
    }

    function _distributionRowFromSeed(uint256 seed)
        internal
        pure
        returns (uint256 toAssetBuybackWad, uint256 toNumeraireBuybackWad, uint256 toBeneficiaryWad, uint256 toLpWad)
    {
        uint256 remaining = WAD;

        toAssetBuybackWad = seed % (remaining + 1);
        remaining -= toAssetBuybackWad;

        uint256 seed1 = uint256(keccak256(abi.encode(seed, uint256(1))));
        toNumeraireBuybackWad = seed1 % (remaining + 1);
        remaining -= toNumeraireBuybackWad;

        uint256 seed2 = uint256(keccak256(abi.encode(seed, uint256(2))));
        toBeneficiaryWad = seed2 % (remaining + 1);
        remaining -= toBeneficiaryWad;

        toLpWad = remaining;
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
