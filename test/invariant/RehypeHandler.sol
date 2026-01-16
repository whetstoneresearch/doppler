// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Constants } from "@v4-core-test/utils/Constants.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, equals, lessThan } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IV4Quoter, V4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Airlock } from "src/Airlock.sol";
import { ON_GRADUATION_FLAG, ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import { EPSILON, RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { DopplerHookInitializer, InitData } from "src/initializers/DopplerHookInitializer.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { alignTick } from "src/libraries/TickLibrary.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import { AddressSet, LibAddressSet } from "test/invariant/AddressSet.sol";
import { CustomRevertDecoder } from "test/utils/CustomRevertDecoder.sol";

uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

address constant AIRLOCK_OWNER = 0xf00000000000000000000000000000000000B055;

contract RehyperInvariantTests is Deployers {
    Airlock public airlock;
    DopplerHookInitializer public dopplerHookInitializer;
    RehypeDopplerHook public rehypeHook;
    RehypeHandler public handler;
    V4Quoter public quoter;

    function setUp() public {
        deployFreshManager();
        swapRouter = new PoolSwapTest(manager);

        dopplerHookInitializer = DopplerHookInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );
        rehypeHook = new RehypeDopplerHook(address(dopplerHookInitializer), manager);
        quoter = new V4Quoter(manager);
        handler = new RehypeHandler(manager, swapRouter, dopplerHookInitializer, rehypeHook, quoter);

        // No need for the Airlock in this case we can simply use the handler instead
        deployCodeTo(
            "DopplerHookInitializer", abi.encode(address(handler), address(manager)), address(dopplerHookInitializer)
        );

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.initialize.selector;
        selectors[1] = handler.buyExactIn.selector;
        selectors[2] = handler.buyExactOut.selector;
        selectors[3] = handler.sellExactIn.selector;
        selectors[4] = handler.sellExactOut.selector;
        selectors[5] = handler.setFeeDistribution.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        address[] memory hooks = new address[](1);
        hooks[0] = address(rehypeHook);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_GRADUATION_FLAG | ON_SWAP_FLAG;
        vm.prank(AIRLOCK_OWNER);
        dopplerHookInitializer.setDopplerHookState(hooks, flags);
    }

    function invariant_HookIsAlwaysSolvent() public view {
        uint256 poolKeysLength = handler.poolKeysLength();

        for (uint256 i; i < poolKeysLength; i++) {
            PoolKey memory poolKey = handler.getPoolKey(i);
            PoolId poolId = poolKey.toId();

            (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,) = rehypeHook.getHookFees(poolId);
            assertGe(poolKey.currency0.balanceOf(address(rehypeHook)), beneficiaryFees0, "Insolvent for currency0");
            assertGe(poolKey.currency1.balanceOf(address(rehypeHook)), beneficiaryFees1, "Insolvent for currency1");
        }
    }

    function invariant_NoFeesAboveEpsilon() public view {
        uint256 poolKeysLength = handler.poolKeysLength();

        for (uint256 i; i < poolKeysLength; i++) {
            PoolKey memory poolKey = handler.getPoolKey(i);
            PoolId poolId = poolKey.toId();

            (uint128 fees0, uint128 fees1,,,) = rehypeHook.getHookFees(poolId);
            assertGe(EPSILON, fees0, "Excessive fees0 accumulated");
            assertGe(EPSILON, fees1, "Excessive fees1 accumulated");
        }
    }

    function invariant_FullRangeLiquidityNeverDecreases() public view {
        uint256 poolKeysLength = handler.poolKeysLength();

        for (uint256 i; i < poolKeysLength; i++) {
            PoolKey memory poolKey = handler.getPoolKey(i);
            PoolId poolId = poolKey.toId();

            uint256 ghostLiquidity = handler.ghost_liquidityOf(poolId);
            (,, uint256 currentLiquidity,) = rehypeHook.getPosition(poolId);
            assertGe(currentLiquidity, ghostLiquidity, "Full range liquidity decreased");
        }
    }
}

struct Settings {
    address asset;
    address numeraire;
    address buybackDst;
    uint24 customFee;
    uint256 assetBuybackPercentWad;
    uint256 numeraireBuybackPercentWad;
    uint256 beneficiaryPercentWad;
    uint256 lpPercentWad;
    bool isToken0;
}

contract RehypeHandler is Test {
    using LibAddressSet for AddressSet;

    IPoolManager public manager;
    RehypeDopplerHook public hook;
    PoolSwapTest public swapRouter;
    DopplerHookInitializer public dopplerHookInitializer;
    V4Quoter public quoter;

    mapping(PoolId => Settings) public settingsOf;
    PoolKey[] public poolKeys;
    uint256 public poolKeysLength;
    address[] public availableNumeraires;

    mapping(PoolId => uint256) public totalBuys;
    mapping(PoolId => uint256) public totalSells;

    mapping(PoolId => uint256) public ghost_hookFees0;
    mapping(PoolId => uint256) public ghost_hookFees1;

    mapping(PoolId => uint256) public ghost_beneficiaryFees0;
    mapping(PoolId => uint256) public ghost_beneficiaryFees1;

    mapping(PoolId => uint256) public ghost_liquidityOf;

    AddressSet internal actors;
    address internal currentActor;

    modifier createActor() {
        // We "randomize" the actor to avoid any collisions with existing contracts
        currentActor = address(uint160(msg.sender) | uint160(0xfFfFFFFfFF000000000000000000000000000000));
        actors.add(currentActor);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors.rand(actorIndexSeed);
        if (currentActor == address(0)) {
            currentActor = address(uint160(msg.sender) | uint160(0xfFfFFFFfFF000000000000000000000000000000));
            actors.add(currentActor);
        }
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        DopplerHookInitializer dopplerHookInitializer_,
        RehypeDopplerHook hook_,
        V4Quoter quoter_
    ) {
        manager = manager_;
        hook = hook_;
        swapRouter = swapRouter_;
        dopplerHookInitializer = dopplerHookInitializer_;
        quoter = quoter_;

        availableNumeraires.push(address(0));

        for (uint256 i; i < 2; i++) {
            availableNumeraires.push(address(new TestERC20(0)));
        }
    }

    /* ------------------------------------------------------------------------------ */
    /*                                Target functions                                */
    /* ------------------------------------------------------------------------------ */

    function initialize(uint256 seed) public {
        // Only 5% chance to initialize a new pool
        vm.assume(seed % 100 > 5);

        address numeraire = availableNumeraires[seed % availableNumeraires.length];
        address asset = address(new TestERC20(1e27));

        // TODO: Randomize fee and tick spacing
        PoolKey memory poolKey = PoolKey({
            currency0: numeraire < asset ? Currency.wrap(numeraire) : Currency.wrap(asset),
            currency1: numeraire < asset ? Currency.wrap(asset) : Currency.wrap(numeraire),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 8,
            hooks: IHooks(address(dopplerHookInitializer))
        });
        poolKeys.push(poolKey);
        poolKeysLength++;

        PoolId poolId = poolKey.toId();

        TestERC20(asset).approve(address(dopplerHookInitializer), type(uint256).max);

        InitData memory data = _prepareInitData(seed);

        (
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        ) = _randomizeFeeDistribution(seed);

        // TODO: Fuzz these parameters
        Settings memory settings = Settings({
            asset: asset,
            numeraire: numeraire,
            buybackDst: address(0xbeef),
            customFee: 300,
            assetBuybackPercentWad: assetBuybackPercentWad,
            numeraireBuybackPercentWad: numeraireBuybackPercentWad,
            beneficiaryPercentWad: beneficiaryPercentWad,
            lpPercentWad: lpPercentWad,
            isToken0: Currency.unwrap(poolKey.currency0) == asset
        });

        data.onInitializationDopplerHookCalldata = abi.encode(
            numeraire,
            address(0xbeef),
            3000,
            settings.assetBuybackPercentWad,
            settings.numeraireBuybackPercentWad,
            settings.beneficiaryPercentWad,
            settings.lpPercentWad
        );
        dopplerHookInitializer.initialize(address(asset), numeraire, 1e27, bytes32(0), abi.encode(data));

        settingsOf[poolId] = settings;
    }

    function buyExactIn(uint256 amount) public createActor {
        if (poolKeys.length == 0) return;

        // TODO: Fuzz the amount
        amount = 1e18;

        PoolKey memory poolKey = poolKeys[amount % poolKeys.length];
        PoolId poolId = poolKey.toId();

        Settings memory settings = settingsOf[poolId];

        if (settings.numeraire == address(0)) {
            deal(currentActor, amount);
        } else {
            deal(settings.numeraire, currentActor, amount);
            TestERC20(settings.numeraire).approve(address(swapRouter), amount);
        }

        // TODO: Do something with the delta
        // TODO: Track hook fees before and after the swap
        try swapRouter.swap{ value: settings.numeraire == address(0) ? amount : 0 }(
            poolKey,
            IPoolManager.SwapParams(
                !settings.isToken0, -int256(amount), settings.isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta delta
        ) { }
        catch (bytes memory err) {
            bytes4 selector;

            assembly {
                selector := mload(add(err, 0x20))
            }

            if (selector == CustomRevert.WrappedError.selector) {
                (,,, bytes4 revertReasonSelector,,) = CustomRevertDecoder.decode(err);
                console.logBytes4(revertReasonSelector);
                revert("Buy reverted");
            } else {
                revert("Unknown error");
            }
        }

        totalBuys[poolId]++;

        _trackLiquidity(poolId);
    }

    function buyExactOut(uint256 amountOut) public createActor {
        if (poolKeys.length == 0) return;

        amountOut = 1e18;

        PoolKey memory poolKey = poolKeys[amountOut % poolKeys.length];
        PoolId poolId = poolKey.toId();

        Settings memory settings = settingsOf[poolId];

        (uint256 amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: !settings.isToken0,
                exactAmount: uint128(amountOut),
                hookData: new bytes(0)
            })
        );

        if (settings.numeraire == address(0)) {
            deal(currentActor, amountIn);
        } else {
            deal(settings.numeraire, currentActor, amountIn);
            TestERC20(settings.numeraire).approve(address(swapRouter), amountIn);
        }

        // TODO: Do something with the delta
        // TODO: Track hook fees before and after the swap
        try swapRouter.swap{ value: settings.numeraire == address(0) ? amountIn : 0 }(
            poolKey,
            IPoolManager.SwapParams(
                !settings.isToken0, int256(amountOut), settings.isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta delta
        ) { }
        catch (bytes memory err) {
            bytes4 selector;

            assembly {
                selector := mload(add(err, 0x20))
            }

            if (selector == CustomRevert.WrappedError.selector) {
                (,,, bytes4 revertReasonSelector,,) = CustomRevertDecoder.decode(err);
                console.logBytes4(revertReasonSelector);
                revert("Buy reverted");
            } else {
                revert("Unknown error");
            }
        }

        totalBuys[poolId]++;

        _trackLiquidity(poolId);
    }

    function sellExactIn(uint256 seed) public useActor(seed) {
        if (currentActor == address(0)) return;
        if (poolKeys.length == 0) return;

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();

        Settings memory settings = settingsOf[poolId];

        uint256 currentBalance = TestERC20(settings.asset).balanceOf(currentActor);
        if (currentBalance == 0) {
            return;
        }

        // TODO: Fuzz the amount
        uint256 amount = currentBalance;

        TestERC20(settings.asset).approve(address(swapRouter), amount);

        // TODO: Do something with the delta
        // TODO: Track hook fees before and after the swap
        try swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(
                settings.isToken0, -int256(amount), settings.isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta delta
        ) { }
        catch (bytes memory err) {
            bytes4 selector;

            assembly {
                selector := mload(add(err, 0x20))
            }

            if (selector == CustomRevert.WrappedError.selector) {
                (,,, bytes4 revertReasonSelector,,) = CustomRevertDecoder.decode(err);
                console.logBytes4(revertReasonSelector);
                revert("Sell reverted");
            } else {
                revert("Unknown error");
            }
        }

        totalSells[poolId]++;

        _trackLiquidity(poolId);
    }

    function sellExactOut(uint256 seed) public useActor(seed) {
        if (currentActor == address(0)) return;
        if (poolKeys.length == 0) return;

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();

        Settings memory settings = settingsOf[poolId];

        uint256 currentBalance = TestERC20(settings.asset).balanceOf(currentActor);
        if (currentBalance == 0) {
            return;
        }

        // Let's see how much we can get if we sell all our tokens
        (uint256 amountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: !settings.isToken0,
                exactAmount: uint128(currentBalance),
                hookData: new bytes(0)
            })
        );

        // Let's sell half of it
        amountOut /= 2;

        (uint256 amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: !settings.isToken0,
                exactAmount: uint128(amountOut),
                hookData: new bytes(0)
            })
        );

        TestERC20(settings.asset).approve(address(swapRouter), amountIn);

        // TODO: Do something with the delta
        // TODO: Track hook fees before and after the swap
        try swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(
                settings.isToken0, int256(amountOut), settings.isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta delta
        ) { }
        catch (bytes memory err) {
            bytes4 selector;

            assembly {
                selector := mload(add(err, 0x20))
            }

            if (selector == CustomRevert.WrappedError.selector) {
                (,,, bytes4 revertReasonSelector,,) = CustomRevertDecoder.decode(err);
                console.logBytes4(revertReasonSelector);
                revert("Sell reverted");
            } else {
                revert("Unknown error");
            }
        }

        totalSells[poolId]++;

        _trackLiquidity(poolId);
    }

    function setFeeDistribution(uint256 seed) public {
        if (poolKeys.length == 0) return;
        // Only 0.5% chance to set fee distribution
        if (seed < WAD) seed = WAD;
        vm.assume(seed % 1000 > 5);

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();

        (
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        ) = _randomizeFeeDistribution(seed);

        vm.prank(settingsOf[poolId].buybackDst);
        hook.setFeeDistribution(
            poolId, assetBuybackPercentWad, numeraireBuybackPercentWad, beneficiaryPercentWad, lpPercentWad
        );
    }

    function collectFees(uint256 seed) public {
        if (poolKeys.length == 0) return;
        // Only 2% chance to collect fees
        vm.assume(seed % 100 > 2);

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();
        address asset = settingsOf[poolId].asset;
        BalanceDelta delta = hook.collectFees(asset);
    }

    /* --------------------------------------------------------------------------------------- */
    /*                                External helper functions                                */
    /* --------------------------------------------------------------------------------------- */

    function getPoolKey(uint256 index) external view returns (PoolKey memory) {
        return poolKeys[index];
    }

    // We need an owner function to mock the Airlock owner
    function owner() external pure returns (address) {
        return AIRLOCK_OWNER;
    }

    /* --------------------------------------------------------------------------------------- */
    /*                                Internal helper functions                                */
    /* --------------------------------------------------------------------------------------- */

    function _randomizeCurves(uint256 seed, int24 tickSpacing) internal pure returns (Curve[] memory curves) {
        curves = new Curve[](4);

        int24 tickLower = 160_000 / tickSpacing * tickSpacing;
        int24 tickUpper = 240_000 / tickSpacing * tickSpacing;

        for (uint24 i; i < curves.length; i++) {
            curves[i].tickLower = int24(tickLower + int24(i) * tickSpacing);
            curves[i].tickUpper = tickUpper;
            curves[i].numPositions = 1; //uint16(_randomUint(1, 10, seed + i));
            curves[i].shares = WAD / curves.length;
        }
    }

    function _prepareInitData(uint256 seed) internal returns (InitData memory) {
        // TODO: Randomize curves
        int24 tickSpacing = int24(uint24(_randomUint(1, uint256(uint16(type(int16).max)), seed)));
        tickSpacing = 8;

        Curve[] memory curves = _randomizeCurves(seed, tickSpacing);

        // TODO: Randomize beneficiaries
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });

        return InitData({
            fee: 3000,
            tickSpacing: tickSpacing,
            curves: curves,
            beneficiaries: beneficiaries,
            dopplerHook: address(hook),
            onInitializationDopplerHookCalldata: new bytes(0),
            graduationDopplerHookCalldata: new bytes(0),
            farTick: 200_000
        });
    }

    function _trackLiquidity(PoolId poolId) internal {
        (,, uint256 liquidity,) = hook.getPosition(poolId);
        ghost_liquidityOf[poolId] = liquidity;
    }

    function _randomizeFeeDistribution(uint256 seed)
        internal
        pure
        returns (
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        )
    {
        assetBuybackPercentWad = seed % WAD;
        numeraireBuybackPercentWad = seed % (WAD - assetBuybackPercentWad);
        beneficiaryPercentWad = seed % (WAD - assetBuybackPercentWad - numeraireBuybackPercentWad);
        lpPercentWad = WAD - assetBuybackPercentWad - numeraireBuybackPercentWad - beneficiaryPercentWad;
    }

    function _randomUint(uint256 min, uint256 max, uint256 seed) internal pure returns (uint256) {
        return (seed % (max - min)) + min;
    }
}
